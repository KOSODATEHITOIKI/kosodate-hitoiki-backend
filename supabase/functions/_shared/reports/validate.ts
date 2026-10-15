import { graphemeCount, type Validated } from "../profile/validate.ts";
import { validateUuid } from "../posts/validate.ts";
import type { ModerationAction, ReportReason } from "./types.ts";

const fail = (field: string, message: string, limit?: number): Validated<never> => ({
  ok: false,
  field,
  message,
  limit,
});

/** 通報理由6種（Notion F-05）。 */
export const REPORT_REASONS: readonly ReportReason[] = [
  "harassment",
  "personal_info",
  "spam",
  "copyright",
  "danger",
  "other",
];
export const REPORT_DETAIL_MAX = 200;
export const MODERATION_REASON_MAX = 500;

export function validateReason(input: unknown): Validated<ReportReason> {
  return (REPORT_REASONS as readonly unknown[]).includes(input)
    ? { ok: true, value: input as ReportReason }
    : fail("reason", "通報の理由が正しくありません。");
}

/** 補足は任意。空は null。 */
export function validateDetail(input: unknown): Validated<string | null> {
  if (input === undefined || input === null) return { ok: true, value: null };
  if (typeof input !== "string") return fail("detail", "補足の形式が正しくありません。");
  const detail = input.trim();
  if (detail === "") return { ok: true, value: null };
  if (graphemeCount(detail) > REPORT_DETAIL_MAX) {
    return fail(
      "detail",
      `補足は${REPORT_DETAIL_MAX}文字以内で入力してください。`,
      REPORT_DETAIL_MAX,
    );
  }
  return { ok: true, value: detail };
}

export function validateReportTarget(input: unknown): Validated<"post" | "comment"> {
  return input === "post" || input === "comment"
    ? { ok: true, value: input }
    : fail("target_type", "通報の対象が正しくありません。");
}

export const MODERATION_ACTIONS: readonly ModerationAction[] = [
  "unhide",
  "delete",
  "warn",
  "suspend",
  "guide",
];

export function validateModerationAction(input: unknown): Validated<ModerationAction> {
  return (MODERATION_ACTIONS as readonly unknown[]).includes(input)
    ? { ok: true, value: input as ModerationAction }
    : fail("action", "操作の種類が正しくありません。");
}

export function validateModerationTarget(input: unknown): Validated<"post" | "comment" | "user"> {
  return input === "post" || input === "comment" || input === "user"
    ? { ok: true, value: input }
    : fail("target_type", "対象の種類が正しくありません。");
}

/** 本人へ通知する理由。任意。空は null。 */
export function validateModerationReason(input: unknown): Validated<string | null> {
  if (input === undefined || input === null) return { ok: true, value: null };
  if (typeof input !== "string") return fail("reason", "理由の形式が正しくありません。");
  const reason = input.trim();
  if (reason === "") return { ok: true, value: null };
  if (graphemeCount(reason) > MODERATION_REASON_MAX) {
    return fail(
      "reason",
      `理由は${MODERATION_REASON_MAX}文字以内で入力してください。`,
      MODERATION_REASON_MAX,
    );
  }
  return { ok: true, value: reason };
}

export { validateUuid };
