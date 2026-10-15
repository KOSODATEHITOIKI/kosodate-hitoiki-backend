import { pushMessage } from "./messages.ts";
import type { PushJob, PushOutcome, PushSender } from "./types.ts";

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";

function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const textBytes = (s: string) => new TextEncoder().encode(s);

function pemToDer(pem: string): Uint8Array {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

/** サービスアカウントのJSON文字列を読む。形が違えば null（未設定として扱う）。 */
export function parseServiceAccount(json: string | undefined): ServiceAccount | null {
  if (!json) return null;
  try {
    const v = JSON.parse(json);
    if (
      typeof v.project_id === "string" && typeof v.client_email === "string" &&
      typeof v.private_key === "string"
    ) {
      return v as ServiceAccount;
    }
  } catch {
    // 読めない設定は未設定として扱う（内容はログに出さない）
  }
  return null;
}

/** サービスアカウントの鍵でJWTを作り、アクセストークンと交換する。有効期間内は使い回す。 */
function createTokenSource(
  account: ServiceAccount,
  fetchFn: typeof fetch,
  nowMs: () => number,
) {
  let cached: { token: string; expiresAt: number } | null = null;

  async function fetchToken(): Promise<string> {
    const iat = Math.floor(nowMs() / 1000);
    const aud = account.token_uri ?? DEFAULT_TOKEN_URI;
    const header = base64url(textBytes(JSON.stringify({ alg: "RS256", typ: "JWT" })));
    const claims = base64url(textBytes(JSON.stringify({
      iss: account.client_email,
      scope: SCOPE,
      aud,
      iat,
      exp: iat + 3600,
    })));
    const key = await crypto.subtle.importKey(
      "pkcs8",
      pemToDer(account.private_key) as BufferSource,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const signature = new Uint8Array(
      await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, textBytes(`${header}.${claims}`)),
    );
    const assertion = `${header}.${claims}.${base64url(signature)}`;
    const res = await fetchFn(aud, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion,
      }),
    });
    if (!res.ok) throw new Error("token exchange failed");
    const data = await res.json();
    if (typeof data.access_token !== "string") throw new Error("token exchange failed");
    const ttl = typeof data.expires_in === "number" ? data.expires_in : 3600;
    cached = { token: data.access_token, expiresAt: nowMs() + (ttl - 60) * 1000 };
    return data.access_token;
  }

  return {
    async get(): Promise<string> {
      return cached && cached.expiresAt > nowMs() ? cached.token : await fetchToken();
    },
    clear() {
      cached = null;
    },
  };
}

/** FCMのエラー応答から、既知のエラーコードと説明文だけを取り出す（応答の本文そのものは保持しない）。 */
async function readFcmError(res: Response): Promise<{ code: string | null; message: string }> {
  try {
    const body = await res.json();
    const error = body?.error ?? {};
    const details: unknown[] = Array.isArray(error.details) ? error.details : [];
    // FcmError の errorCode（UNREGISTERED・SENDER_ID_MISMATCH など）が最も正確
    const fcm = details.find((d) =>
      typeof d === "object" && d !== null &&
      typeof (d as Record<string, unknown>).errorCode === "string"
    ) as { errorCode: string } | undefined;
    const status = typeof error.status === "string" ? error.status : null;
    return {
      code: fcm?.errorCode ?? status,
      message: typeof error.message === "string" ? error.message : "",
    };
  } catch {
    return { code: null, message: "" };
  }
}

/**
 * 失敗の分類。**端末が無効と確定できるときだけ**、端末を削除する（invalid_token）。
 * 404や400は、プロジェクトIDの設定誤り・送信内容の不備でも起きる。それらで有効な端末の登録と
 * 配信キューを消さないよう、HTTPステータスだけでは判断しない。
 *   - UNREGISTERED（アプリの削除・トークンの失効）→ 端末が無効
 *   - INVALID_ARGUMENT のうち、メッセージがトークンの不正を指すもの → 端末が無効
 *   - それ以外（設定誤り・送信の不備・認証・混雑・障害）→ 再試行（5回で打ち切り。端末は消さない）
 */
async function classifyFailure(
  res: Response,
  clearToken: () => void,
): Promise<{ outcome: PushOutcome; errorCode?: string }> {
  const { code, message } = await readFcmError(res);
  if (code === "UNREGISTERED") return { outcome: "invalid_token" };
  if (code === "INVALID_ARGUMENT" && /registration token|device token/i.test(message)) {
    return { outcome: "invalid_token" };
  }
  if (res.status === 401 || res.status === 403 || code === "UNAUTHENTICATED") {
    clearToken();
    return { outcome: "retry", errorCode: "FCM_AUTH" };
  }
  if (code === "INVALID_ARGUMENT") return { outcome: "retry", errorCode: "FCM_INVALID_ARGUMENT" };
  return { outcome: "retry", errorCode: `FCM_${res.status}` };
}

/** FCM HTTP v1 で送る。結果は「送れた／再試行／端末が無効」の3つに分ける。応答の本文は読まない。 */
export function createFcmSender(
  account: ServiceAccount,
  fetchFn: typeof fetch = fetch,
  nowMs: () => number = Date.now,
): PushSender {
  const tokens = createTokenSource(account, fetchFn, nowMs);
  const clearToken = () => tokens.clear();

  return {
    async send(job: PushJob): Promise<{ outcome: PushOutcome; errorCode?: string }> {
      let accessToken: string;
      try {
        accessToken = await tokens.get();
      } catch {
        return { outcome: "retry", errorCode: "FCM_AUTH" };
      }

      const { title, body } = pushMessage(job.notificationType);
      let res: Response;
      try {
        res = await fetchFn(
          `https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization: `Bearer ${accessToken}`,
            },
            body: JSON.stringify({
              message: {
                token: job.deviceToken,
                notification: { title, body },
                // 本文は含めない。アプリが開いたときに、通知IDから取得する。
                data: { type: job.notificationType, notification_id: job.notificationId },
                android: { priority: "HIGH" },
                apns: {
                  headers: { "apns-priority": "10" },
                  payload: { aps: { sound: "default" } },
                },
              },
            }),
          },
        );
      } catch {
        return { outcome: "retry", errorCode: "FCM_NETWORK" };
      }

      if (res.ok) {
        await res.body?.cancel();
        return { outcome: "sent" };
      }
      return await classifyFailure(res, clearToken);
    },
  };
}
