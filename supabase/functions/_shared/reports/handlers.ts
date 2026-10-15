import {
  errorResponse,
  jsonResponse,
  methodNotAllowed,
  preflight,
  readJsonObject,
  unauthenticated,
} from "../http.ts";
import type { Validated } from "../profile/validate.ts";
import { type ReportsDeps, ReportsRuleError } from "./types.ts";
import {
  validateDetail,
  validateModerationAction,
  validateModerationReason,
  validateModerationTarget,
  validateReason,
  validateReportTarget,
  validateUuid,
} from "./validate.ts";

const invalidRequest = () =>
  errorResponse(422, "VALIDATION_FAILED", "リクエストの形式が正しくありません。");

function invalid(v: Extract<Validated<unknown>, { ok: false }>): Response {
  return errorResponse(422, "VALIDATION_FAILED", v.message, { field: v.field, limit: v.limit });
}

/** 業務ルール違反を、API契約のレスポンスへ。内部エラーの詳細は返さない。 */
function errorToResponse(e: unknown): Response {
  if (e instanceof ReportsRuleError) {
    switch (e.code) {
      case "NOT_FOUND":
        return errorResponse(404, "NOT_FOUND", "対象が見つかりません。");
      case "FORBIDDEN":
        return errorResponse(403, "FORBIDDEN", "この操作はできません。", { reason: "not_allowed" });
      case "RESTRICTED":
        return errorResponse(403, "FORBIDDEN", "現在、この操作は利用できません。", {
          reason: "restricted",
        });
      case "PROFILE_REQUIRED":
        return errorResponse(403, "FORBIDDEN", "先にプロフィールを登録してください。", {
          reason: "profile_required",
        });
      case "CONFLICT":
        return errorResponse(409, "CONFLICT", "すでに利用停止中です。");
      case "VALIDATION_FAILED":
        return errorResponse(422, "VALIDATION_FAILED", "入力内容を確認してください。");
    }
  }
  console.error("reports function failed", e instanceof Error ? e.name : "unknown");
  return errorResponse(
    500,
    "INTERNAL_ERROR",
    "処理に失敗しました。しばらくしてからもう一度お試しください。",
  );
}

/** POST /reports：通報の送信（ログイン必須）。通報者の情報は、通報された側へ一切出さない。 */
export function reportsHandler(deps: ReportsDeps) {
  return async (req: Request): Promise<Response> => {
    const early = preflight(req);
    if (early) return early;
    if (req.method !== "POST") return methodNotAllowed();

    const auth = await deps.authenticate(req);
    if (!auth) return unauthenticated();
    const body = await readJsonObject(req);
    if (!body) return invalidRequest();

    const type = validateReportTarget(body.target_type);
    if (!type.ok) return invalid(type);
    const target = validateUuid(body.target_id, "target_id");
    if (!target.ok) return invalid(target);
    const reason = validateReason(body.reason);
    if (!reason.ok) return invalid(reason);
    const detail = validateDetail(body.detail);
    if (!detail.ok) return invalid(detail);

    try {
      const result = await deps.db.createReport({
        reporterId: auth.userId,
        targetType: type.value,
        targetId: target.value,
        reason: reason.value,
        detail: detail.value,
      });
      // 重複した通報（同じ対象の未対応の通報が既にある）は、同じ内容を返す。
      return jsonResponse(result.duplicate ? 200 : 201, result);
    } catch (e) {
      return errorToResponse(e);
    }
  };
}

/** `/moderation/actions` に対応づける（関数名より前の接頭辞は無視）。 */
export function isModerationActionsPath(pathname: string): boolean {
  return /(?:^|\/)moderation\/actions\/?$/.test(pathname);
}

/**
 * POST /moderation/actions：運営の対処（運営者専用）。
 * - 運営者として登録されていない利用者には、この機能の存在を明かさない（404）。
 * - 運営者でも、二段階認証（aal2）を済ませていないセッションは拒否する（403）。
 * - DB関数も、運営者の登録を確認する（この確認に頼りきらない）。
 */
export function moderationHandler(deps: ReportsDeps) {
  return async (req: Request): Promise<Response> => {
    const early = preflight(req);
    if (early) return early;
    if (!isModerationActionsPath(new URL(req.url).pathname)) {
      return errorResponse(404, "NOT_FOUND", "対象が見つかりません。");
    }
    if (req.method !== "POST") return methodNotAllowed();

    const auth = await deps.authenticate(req);
    if (!auth) return unauthenticated();

    try {
      if (!(await deps.db.isRegisteredAdmin(auth.userId))) {
        return errorResponse(404, "NOT_FOUND", "対象が見つかりません。");
      }
      if (auth.aal !== "aal2") {
        return errorResponse(403, "FORBIDDEN", "二段階認証が必要です。", {
          reason: "mfa_required",
        });
      }

      const body = await readJsonObject(req);
      if (!body) return invalidRequest();
      const type = validateModerationTarget(body.target_type);
      if (!type.ok) return invalid(type);
      const target = validateUuid(body.target_id, "target_id");
      if (!target.ok) return invalid(target);
      const action = validateModerationAction(body.action);
      if (!action.ok) return invalid(action);
      const reason = validateModerationReason(body.reason);
      if (!reason.ok) return invalid(reason);

      const result = await deps.db.applyModeration({
        adminId: auth.userId,
        targetType: type.value,
        targetId: target.value,
        action: action.value,
        reason: reason.value,
      });
      return jsonResponse(200, result);
    } catch (e) {
      return errorToResponse(e);
    }
  };
}
