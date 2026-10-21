/** Edge Functions共通のHTTPヘルパー。エラー形式は docs/API契約.md に従う。 */

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, content-type, apikey, x-client-info, idempotency-key",
  "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
};

export function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

/** 本文・APIキー・内部エラーの詳細はメッセージや details に入れない。 */
export function errorResponse(
  status: number,
  code: string,
  message: string,
  details?: Record<string, unknown>,
): Response {
  return jsonResponse(status, { error: { code, message, details } });
}

/**
 * ハンドラーの最も外側に付けて、想定外の例外（Authへの問い合わせの失敗など、各ハンドラーのtryの外で起きるもの）を、
 * どの機能でも同じ500にそろえる。内部の詳細・本文・鍵は返さず、ログにも例外の種類（名前）だけを残す。
 */
export function guarded(
  handler: (req: Request) => Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req) => {
    try {
      return await handler(req);
    } catch (e) {
      console.error("unhandled error in function", e instanceof Error ? e.name : "unknown");
      return errorResponse(
        500,
        "INTERNAL_ERROR",
        "処理に失敗しました。しばらくしてからもう一度お試しください。",
      );
    }
  };
}

/** ブラウザ（Flutter web）からのプリフライト。それ以外は null。 */
export function preflight(req: Request): Response | null {
  return req.method === "OPTIONS"
    ? new Response(null, { status: 204, headers: CORS_HEADERS })
    : null;
}

/** JSONオブジェクトの本文を読む。不正な場合は null。 */
export async function readJsonObject(req: Request): Promise<Record<string, unknown> | null> {
  try {
    const body = await req.json();
    return body !== null && typeof body === "object" && !Array.isArray(body)
      ? body as Record<string, unknown>
      : null;
  } catch {
    return null;
  }
}

export const unauthenticated = () => errorResponse(401, "UNAUTHENTICATED", "ログインが必要です。");

export const methodNotAllowed = () =>
  errorResponse(405, "VALIDATION_FAILED", "このメソッドは使えません。");
