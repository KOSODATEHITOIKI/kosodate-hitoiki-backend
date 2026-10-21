import type { CheckDeps } from "../moderation/types.ts";
import type { CommentAcceptance, PostType, ReactionMode } from "./validate.ts";

/** DB関数（RPC）の呼び出し。実装は wiring.ts、テストではフェイクを使う。 */
export interface PostsDb {
  /**
   * 外部API（送信前チェック）を呼ぶ前の確認。操作の資格（利用停止・プロフィール）、登録直後の上限、
   * 利用者ごとのリクエスト上限。通らなければ、外部APIを呼ばずに止める。
   */
  preflight(
    userId: string,
    kind: "post" | "comment" | "edit",
    idempotencyKey?: string | null,
  ): Promise<void>;
  /**
   * 完了済みのIdempotency-Keyの保存済みの結果。なければ null。外部API（送信前チェック）を呼ぶ前に確かめ、
   * 外部APIが止まっていても、保存済みの結果は返せるようにする。
   */
  replayResponse(
    userId: string,
    kind: "post" | "comment",
    key: string,
  ): Promise<Record<string, unknown> | null>;
  /** 作成の応答の「相談先の案内」を、再送でも返せるよう、保存済みの結果へ書き足す。 */
  rememberSupportNotice(userId: string, kind: "post" | "comment", key: string): Promise<void>;
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
  setReaction(
    userId: string,
    postId: string,
    reactionTypeId: number,
  ): Promise<{ post_id: string; reaction_type_id: number; updated_at: string }>;
  removeReaction(userId: string, postId: string): Promise<{ deleted: boolean }>;
}

export interface PostsDeps {
  /** Authorizationヘッダーを検証し、ユーザーIDを返す。未ログインなら null。 */
  authenticate(req: Request): Promise<string | null>;
  moderation: CheckDeps;
  db: PostsDb;
}

/** DB関数が返す業務ルール違反。メッセージの内部コードだけを保持する。 */
export class RuleError extends Error {
  constructor(
    public readonly code: string,
    public readonly publicMessage?: string,
    /** RATE_LIMITED のとき、制限が解ける日時（ISO 8601）。 */
    public readonly retryAt?: string,
  ) {
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
  "RATE_LIMITED",
  "REQUEST_LIMITED",
]);

/** 親コメントの階層・所属違反（既存トリガーのメッセージ）。利用者に見せてよい文言だけ通す。 */
const PARENT_RULE_MESSAGES = new Set([
  "返信への返信はできません",
  "親コメントは同じ投稿に属している必要があります",
  "親コメントが見つかりません",
]);

/** PostgRESTのエラーを RuleError へ。コードか既知の文言以外（本文・内部情報を含みうるもの）は捨てる。 */
export function toRuleError(e: { code?: string; message?: string; details?: string }): Error {
  if (e.code === "P0001" && e.message) {
    if (e.message === "RATE_LIMITED" || e.message === "REQUEST_LIMITED") {
      // DETAILに入る「制限が解ける日時」だけを取り出す（日時として読めないものは捨てる）。
      const t = e.details ? new Date(e.details) : null;
      return new RuleError(
        e.message,
        undefined,
        t && !Number.isNaN(t.getTime()) ? t.toISOString() : undefined,
      );
    }
    if (RULE_CODES.has(e.message)) return new RuleError(e.message);
    if (PARENT_RULE_MESSAGES.has(e.message)) return new RuleError("VALIDATION_FAILED", e.message);
  }
  return new Error("database error", { cause: undefined });
}
