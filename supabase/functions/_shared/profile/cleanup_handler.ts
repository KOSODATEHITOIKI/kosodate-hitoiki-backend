import { errorResponse, jsonResponse, methodNotAllowed, preflight } from "../http.ts";
import { JOB_SECRET_HEADER, jobSecretMatches, type JobSecretVerifier } from "../internal_auth.ts";

export interface CleanupDeps {
  /** 受け取った秘密が正しいかを、DB（Vault）に問い合わせて確かめる。未登録なら、誰も起動できない。 */
  verifyJobSecret: JobSecretVerifier;
  /** 削除待ちの画像を最大 limit 件削除し、削除できた件数を返す。 */
  drain(limit: number): Promise<number>;
}

/**
 * POST /storage-cleanup：削除待ちの画像（プロフィールから外れた画像）をStorageから削除する。
 * 利用者の操作の中でも試みるが、失敗した分はここで成功するまで再試行する（定期実行から呼ぶ）。
 * 秘密がない・違う・未設定のときは、この機能の存在を明かさない（404）。
 */
export function storageCleanupHandler(deps: CleanupDeps) {
  return async (req: Request): Promise<Response> => {
    const early = preflight(req);
    if (early) return early;
    if (!(await jobSecretMatches(req.headers.get(JOB_SECRET_HEADER), deps.verifyJobSecret))) {
      return errorResponse(404, "NOT_FOUND", "対象が見つかりません。");
    }
    if (req.method !== "POST") return methodNotAllowed();
    try {
      return jsonResponse(200, { removed: await deps.drain(100) });
    } catch (e) {
      console.error("storage-cleanup failed", e instanceof Error ? e.name : "unknown");
      return errorResponse(
        500,
        "INTERNAL_ERROR",
        "処理に失敗しました。しばらくしてからもう一度お試しください。",
      );
    }
  };
}
