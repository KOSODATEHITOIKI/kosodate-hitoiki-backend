import { errorResponse, jsonResponse, methodNotAllowed, preflight } from "../http.ts";
import type { PushDeps, PushOutcome } from "./types.ts";

const BATCH = 50;
const CONCURRENCY = 10;

/** 長さによらず同じ時間で比べる（秘密の一致を、応答時間から推測させない）。 */
async function secretMatches(given: string, expected: string): Promise<boolean> {
  const hash = async (s: string) =>
    new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  const [a, b] = await Promise.all([hash(given), hash(expected)]);
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

const notFound = () => errorResponse(404, "NOT_FOUND", "対象が見つかりません。");

/**
 * POST /push-dispatch：配信キューを取り出して、FCMへ送る。
 * 起動できるのは、秘密（x-dispatch-secret）を知っている側（定期実行）だけ。
 * 秘密が未設定・不一致のときは、この機能の存在を明かさない（404）。
 */
export function pushDispatchHandler(deps: PushDeps) {
  return async (req: Request): Promise<Response> => {
    const early = preflight(req);
    if (early) return early;

    const given = req.headers.get("x-dispatch-secret");
    if (!deps.dispatchSecret || !given || !(await secretMatches(given, deps.dispatchSecret))) {
      return notFound();
    }
    if (req.method !== "POST") return methodNotAllowed();
    if (!deps.senderConfigured) {
      // 取り出す前に止める（取り出すと、配信の試行回数が減ってしまうため）
      return errorResponse(503, "INTERNAL_ERROR", "プッシュ配信の設定がありません。");
    }

    try {
      const jobs = await deps.db.claim(BATCH);
      const counts: Record<PushOutcome, number> = { sent: 0, retry: 0, invalid_token: 0 };
      let recordFailed = 0;

      for (let i = 0; i < jobs.length; i += CONCURRENCY) {
        await Promise.all(
          jobs.slice(i, i + CONCURRENCY).map(async (job) => {
            let outcome: PushOutcome = "retry";
            let errorCode: string | undefined = "SEND_EXCEPTION";
            try {
              ({ outcome, errorCode } = await deps.sender.send(job));
            } catch {
              // 想定外の失敗は再試行に回す（内容はログに出さない）
            }
            try {
              await deps.db.finish(job.deliveryId, outcome, errorCode);
              counts[outcome]++;
            } catch {
              recordFailed++; // 記録に失敗した分は、ロックが切れたあとに再び取り出される
            }
          }),
        );
      }
      return jsonResponse(200, { claimed: jobs.length, ...counts, record_failed: recordFailed });
    } catch (e) {
      console.error("push-dispatch failed", e instanceof Error ? e.name : "unknown");
      return errorResponse(
        500,
        "INTERNAL_ERROR",
        "処理に失敗しました。しばらくしてからもう一度お試しください。",
      );
    }
  };
}
