import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";

/** Authorization ヘッダーの Bearer トークン。なければ null。 */
export function bearerToken(req: Request): string | null {
  const match = /^Bearer (.+)$/i.exec(req.headers.get("Authorization") ?? "");
  return match ? match[1] : null;
}

/** JWTの本体（payload）を読む。署名の検証は getUser で済ませたトークンにだけ使う。 */
export function readPayload(token: string): Record<string, unknown> {
  const part = token.split(".")[1] ?? "";
  const base64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(
    Math.ceil(part.length / 4) * 4,
    "=",
  );
  try {
    const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
    const payload = JSON.parse(new TextDecoder().decode(bytes));
    return payload !== null && typeof payload === "object" && !Array.isArray(payload)
      ? payload
      : {};
  } catch {
    return {};
  }
}

export interface VerifiedUser {
  userId: string;
  /** Supabase Authが検証したトークンの本体（aal・session_id など）。クライアントの自己申告ではない。 */
  claims: Record<string, unknown>;
}

/**
 * Bearerトークンを Supabase Auth で検証し、利用者IDとクレームを返す。
 * トークンがない・無効（期限切れ・偽造）なら null（呼び出し側は401にする）。
 * Authへ問い合わせられない障害は、例外のまま投げる（最も外側で、500に統一する。http.ts の guarded）。
 */
export async function verifiedUser(
  admin: SupabaseClient,
  req: Request,
): Promise<VerifiedUser | null> {
  const token = bearerToken(req);
  if (!token) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return null;
  return { userId: data.user.id, claims: readPayload(token) };
}
