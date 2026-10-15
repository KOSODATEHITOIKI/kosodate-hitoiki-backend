import {
  errorResponse,
  jsonResponse,
  methodNotAllowed,
  preflight,
  readJsonObject,
  unauthenticated,
} from "../http.ts";
import { type AccountDeps, AccountRuleError } from "./types.ts";

/** 退会に必要な、このセッションが作られてからの経過時間（決定済み：5分以内のログイン）。 */
export const RECENT_LOGIN_MS = 5 * 60 * 1000;

/**
 * POST /account-delete { "confirm": true }：退会（取消期間なし。即時に削除する）。
 * - 本人確認：**この操作に使うセッション**が5分以内に作られていること（メール・Google・Appleで共通）。
 *   古いセッションは、本人が別の端末で再ログインしても通らない（盗まれたセッションでの退会を防ぐ）。
 * - 運営者として登録されている間は退会できない（先に登録を外す）。
 * - 画像を先に削除し、そのあとDBを1トランザクションで削除する。途中で失敗しても、同じ操作を再実行できる。
 */
export function accountDeleteHandler(deps: AccountDeps) {
  const now = deps.now ?? Date.now;
  return async (req: Request): Promise<Response> => {
    const early = preflight(req);
    if (early) return early;
    if (req.method !== "POST") return methodNotAllowed();

    let user;
    try {
      user = await deps.authenticate(req);
    } catch {
      return errorResponse(
        500,
        "INTERNAL_ERROR",
        "処理に失敗しました。しばらくしてからもう一度お試しください。",
      );
    }
    if (!user) return unauthenticated();

    const body = await readJsonObject(req);
    if (!body || body.confirm !== true) {
      return errorResponse(422, "VALIDATION_FAILED", "退会の確認が必要です。", {
        field: "confirm",
      });
    }

    const signedInAt = user.sessionStartedAt ? Date.parse(user.sessionStartedAt) : NaN;
    if (Number.isNaN(signedInAt) || now() - signedInAt > RECENT_LOGIN_MS) {
      return errorResponse(
        403,
        "FORBIDDEN",
        "退会するには、もう一度ログインしてください。",
        { reason: "reauth_required" },
      );
    }

    try {
      if (await deps.db.isOperator(user.userId)) {
        return errorResponse(
          409,
          "CONFLICT",
          "運営者として登録されているため、退会できません。",
          { reason: "operator_registered" },
        );
      }
      await deps.storage.removeAllFor(user.userId);
      const status = await deps.db.withdraw(user.userId);
      return jsonResponse(200, { status });
    } catch (e) {
      if (e instanceof AccountRuleError && e.code === "OPERATOR_REGISTERED") {
        return errorResponse(
          409,
          "CONFLICT",
          "運営者として登録されているため、退会できません。",
          { reason: "operator_registered" },
        );
      }
      console.error("account-delete failed", e instanceof Error ? e.name : "unknown");
      return errorResponse(
        500,
        "INTERNAL_ERROR",
        "処理に失敗しました。しばらくしてからもう一度お試しください。",
      );
    }
  };
}
