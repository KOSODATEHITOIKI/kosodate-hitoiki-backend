import type { CheckDeps } from "../moderation/types.ts";
import type { CommentAcceptance, PostType, ReactionMode } from "./validate.ts";

/** DB関数（RPC）の呼び出し。実装は wiring.ts、テストではフェイクを使う。 */
export interface PostsDb {
  createPost(a: {
    userId: string;
    postType: PostType;
    topicId: number | null;
    body: string;
    reactionMode: ReactionMode;
    idempotencyKey: string | null;
  }): Promise<{ id: string; created_at: string }>;
  updatePostBody(
    userId: string,
    postId: string,
    body: string,
  ): Promise<{ id: string; edited_at: string | null }>;
  deletePost(userId: string, postId: string): Promise<void>;
  setReactionMode(
    userId: string,
    postId: string,
    mode: ReactionMode,
    acceptance: CommentAcceptance | null,
  ): Promise<{ reaction_mode: ReactionMode; comment_acceptance: CommentAcceptance | null }>;
  createComment(a: {
    userId: string;
    postId: string;
    parentCommentId: string | null;
    body: string;
    idempotencyKey: string | null;
  }): Promise<{ id: string; created_at: string }>;
  updateCommentBody(
    userId: string,
    commentId: string,
    body: string,
  ): Promise<{ id: string; edited_at: string | null }>;
  deleteComment(userId: string, commentId: string): Promise<void>;
}

export interface PostsDeps {
  /** Authorizationヘッダーを検証し、ユーザーIDを返す。未ログインなら null。 */
  authenticate(req: Request): Promise<string | null>;
  moderation: CheckDeps;
  db: PostsDb;
}

/** DB関数が返す業務ルール違反。メッセージの内部コードだけを保持する。 */
export class RuleError extends Error {
  constructor(public readonly code: string, public readonly publicMessage?: string) {
    super("rule violation");
    this.name = "RuleError";
  }
}

/** DB関数が `raise exception '<コード>'` で返す内部コード。 */
const RULE_CODES = new Set([
  "NOT_FOUND",
  "FORBIDDEN",
  "RESTRICTED",
  "BLOCKED",
  "COMMENTS_CLOSED",
  "PROFILE_REQUIRED",
  "VALIDATION_FAILED",
]);

/** 親コメントの階層・所属違反（既存トリガーのメッセージ）。利用者に見せてよい文言だけ通す。 */
const PARENT_RULE_MESSAGES = new Set([
  "返信への返信はできません",
  "親コメントは同じ投稿に属している必要があります",
  "親コメントが見つかりません",
]);

/** PostgRESTのエラーを RuleError へ。コードか既知の文言以外（本文・内部情報を含みうるもの）は捨てる。 */
export function toRuleError(e: { code?: string; message?: string }): Error {
  if (e.code === "P0001" && e.message) {
    if (RULE_CODES.has(e.message)) return new RuleError(e.message);
    if (PARENT_RULE_MESSAGES.has(e.message)) return new RuleError("VALIDATION_FAILED", e.message);
  }
  return new Error("database error", { cause: undefined });
}
