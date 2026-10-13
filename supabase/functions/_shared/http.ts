/** Edge Functions共通のHTTPヘルパー。エラー形式は docs/API契約.md に従う。 */

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
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
