import {
  errorResponse,
  jsonResponse,
  methodNotAllowed,
  preflight,
  readJsonObject,
  unauthenticated,
} from "../http.ts";
import { type AccountDeps, AccountRuleError } from "./types.ts";

/** 退会に必要な、直近のログインの新しさ（決定済み：5分以内）。 */
export const RECENT_LOGIN_MS = 5 * 60 * 1000;

/**
 * POST /account-delete { "confirm": true }：退会（取消期間なし。即時に削除する）。
 * - 本人確認：直近5分以内にログインしていること（メール・Google・Appleで共通）。古いセッションでは拒否する。
 * - 運営者として登録されている間は退会できない（先に登録を外す）。
 * - 画像を先に削除し、そのあとDBを1トランザクションで削除する。途中で失敗しても、同じ操作を再実行できる。
 */
export function accountDeleteHandler(deps: AccountDeps) {
  const now = deps.now ?? Date.now;
  return async (req: Request): Promise<Response> => {
    const early = preflight(req);
    if (early) return early;
    if (req.method !== "POST") return methodNotAllowed();

    const user = await deps.authenticate(req);
    if (!user) return unauthenticated();

    const body = await readJsonObject(req);
    if (!body || body.confirm !== true) {
      return errorResponse(422, "VALIDATION_FAILED", "退会の確認が必要です。", {
        field: "confirm",
      });
    }

    const signedInAt = user.lastSignInAt ? Date.parse(user.lastSignInAt) : NaN;
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
