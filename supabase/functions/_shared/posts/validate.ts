import { graphemeCount, type Validated } from "../profile/validate.ts";

/**
 * 投稿・コメントの入力検証。文字数は書記素（見た目の1文字）で数える（決定済み、絵文字も1文字）。
 * 本文は前後の空白を除いて1文字以上（空白のみは不可）。
 */

export const POST_BODY_MAX = 1000;
export const COMMENT_BODY_MAX = 500;

export const POST_TYPES = ["guchi", "soudan", "kotsu"] as const;
export type PostType = typeof POST_TYPES[number];
export const REACTION_MODES = ["quiet_support", "want_comments"] as const;
export type ReactionMode = typeof REACTION_MODES[number];
export type CommentAcceptance = "open" | "closed";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const IDEMPOTENCY_KEY_PATTERN = /^[A-Za-z0-9._:-]{1,64}$/;

const fail = (field: string, message: string, limit?: number): Validated<never> => ({
  ok: false,
  field,
  message,
  limit,
});

function validateBody(input: unknown, max: number, label: string): Validated<string> {
  if (typeof input !== "string") return fail("body", `${label}を入力してください。`);
  const body = input.trim();
  if (body === "") return fail("body", `${label}を入力してください。`);
  if (graphemeCount(body) > max) {
    return fail(
      "body",
      `${label}は${max.toLocaleString("ja-JP")}文字以内で入力してください。`,
      max,
    );
  }
  return { ok: true, value: body };
}

export const validatePostBody = (input: unknown) => validateBody(input, POST_BODY_MAX, "投稿");
export const validateCommentBody = (input: unknown) =>
  validateBody(input, COMMENT_BODY_MAX, "コメント");

export function validatePostType(input: unknown): Validated<PostType> {
  return (POST_TYPES as readonly unknown[]).includes(input)
    ? { ok: true, value: input as PostType }
    : fail("post_type", "投稿の種類が正しくありません。");
}

export function validateReactionMode(input: unknown): Validated<ReactionMode> {
  return (REACTION_MODES as readonly unknown[]).includes(input)
    ? { ok: true, value: input as ReactionMode }
    : fail("reaction_mode", "反応モードが正しくありません。");
}

/** 未指定・null は「話題なし」。 */
export function validateTopicId(input: unknown): Validated<number | null> {
  if (input === undefined || input === null) return { ok: true, value: null };
  if (typeof input !== "number" || !Number.isInteger(input) || input < 1 || input > 32767) {
    return fail("topic_id", "話題の指定が正しくありません。");
  }
  return { ok: true, value: input };
}

export function validateAcceptance(input: unknown): Validated<CommentAcceptance | null> {
  if (input === undefined || input === null) return { ok: true, value: null };
  return input === "open" || input === "closed"
    ? { ok: true, value: input }
    : fail("comment_acceptance", "受付状態が正しくありません。");
}

export function validateUuid(input: unknown, field: string): Validated<string> {
  return typeof input === "string" && UUID_PATTERN.test(input)
    ? { ok: true, value: input.toLowerCase() }
    : fail(field, "IDの形式が正しくありません。");
}

/** Idempotency-Key ヘッダ。未指定は null（再送防止なし）。形式が不正な場合はエラー。 */
export function validateIdempotencyKey(header: string | null): Validated<string | null> {
  if (header === null || header === "") return { ok: true, value: null };
  return IDEMPOTENCY_KEY_PATTERN.test(header)
    ? { ok: true, value: header }
    : fail("Idempotency-Key", "Idempotency-Keyの形式が正しくありません。");
}

/** 共感の定型文ID（運営が用意する定型文の識別子）。 */
export function validateReactionTypeId(input: unknown): Validated<number> {
  return typeof input === "number" && Number.isInteger(input) && input >= 1 && input <= 32767
    ? { ok: true, value: input }
    : fail("reaction_type_id", "定型文の指定が正しくありません。");
}
