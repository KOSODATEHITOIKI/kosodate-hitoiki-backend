import {
  errorResponse,
  jsonResponse,
  methodNotAllowed,
  preflight,
  readJsonObject,
  unauthenticated,
} from "../http.ts";
import { responseForDecision, responseForError } from "../moderation/http.ts";
import { moderateAndSave } from "../moderation/moderate_and_save.ts";
import type { Validated } from "../profile/validate.ts";
import { type PostsDeps, RuleError } from "./types.ts";
import {
  validateAcceptance,
  validateCommentBody,
  validateIdempotencyKey,
  validatePostBody,
  validatePostType,
  validateReactionMode,
  validateTopicId,
  validateUuid,
} from "./validate.ts";

const invalidRequest = () =>
  errorResponse(422, "VALIDATION_FAILED", "リクエストの形式が正しくありません。");

function invalid(v: Extract<Validated<unknown>, { ok: false }>): Response {
  return errorResponse(422, "VALIDATION_FAILED", v.message, { field: v.field, limit: v.limit });
}

/** 業務ルール違反・外部APIの障害を、API契約のレスポンスへ。内部エラーの詳細・本文は返さない。 */
function errorToResponse(e: unknown): Response {
  const unavailable = responseForError(e);
  if (unavailable) return unavailable;

  if (e instanceof RuleError) {
    switch (e.code) {
      case "NOT_FOUND":
        return errorResponse(404, "NOT_FOUND", "対象が見つかりません。");
      case "FORBIDDEN":
        return errorResponse(403, "FORBIDDEN", "この操作はできません。", { reason: "not_owner" });
      case "RESTRICTED":
        return errorResponse(403, "FORBIDDEN", "現在、この操作は利用できません。", {
          reason: "restricted",
        });
      case "BLOCKED":
        return errorResponse(403, "FORBIDDEN", "この操作はできません。", { reason: "blocked" });
      case "COMMENTS_CLOSED":
        return errorResponse(403, "FORBIDDEN", "この投稿はコメントの受付を終了しています。", {
          reason: "comments_closed",
        });
      case "PROFILE_REQUIRED":
        return errorResponse(403, "FORBIDDEN", "先にプロフィールを登録してください。", {
          reason: "profile_required",
        });
      case "VALIDATION_FAILED":
        return errorResponse(
          422,
          "VALIDATION_FAILED",
          e.publicMessage ?? "入力内容を確認してください。",
        );
    }
  }
  console.error("posts function failed", e instanceof Error ? e.name : "unknown");
  return errorResponse(
    500,
    "INTERNAL_ERROR",
    "処理に失敗しました。しばらくしてからもう一度お試しください。",
  );
}

/** `/posts`・`/posts/{id}`・`/posts/{id}/reaction-mode` のどれかに対応づける（関数名より前の接頭辞は無視）。 */
export function routePosts(pathname: string): { id: string | null; sub: string | null } | null {
  const m = /(?:^|\/)posts(?:\/([^/]+))?(?:\/([^/]+))?\/?$/.exec(pathname);
  return m ? { id: m[1] ?? null, sub: m[2] ?? null } : null;
}

/** `/comments`・`/comments/{id}`。 */
export function routeComments(pathname: string): { id: string | null } | null {
  const m = /(?:^|\/)comments(?:\/([^/]+))?\/?$/.exec(pathname);
  return m ? { id: m[1] ?? null } : null;
}

async function context(deps: PostsDeps, req: Request) {
  const userId = await deps.authenticate(req);
  return userId ?? null;
}

/** 本文を送信前チェックにかけ、通ったものだけを保存する。 */
async function checkedSave<T>(
  deps: PostsDeps,
  body: string,
  confirmed: boolean,
  save: (verifiedBody: string) => Promise<T>,
): Promise<{ blocked: Response } | { saved: T; supportNotice: boolean }> {
  const { result, saved } = await moderateAndSave(
    { body },
    deps.moderation,
    { confirmed },
    (verified) => save(verified.body),
  );
  const blocked = responseForDecision(result);
  if (blocked) return { blocked };
  return { saved: saved as T, supportNotice: result.supportNotice };
}

/** POST /posts（作成）、PATCH /posts/{id}（本文の編集）、DELETE /posts/{id}、PATCH /posts/{id}/reaction-mode */
export function postsHandler(deps: PostsDeps) {
  return async (req: Request): Promise<Response> => {
    const early = preflight(req);
    if (early) return early;

    const route = routePosts(new URL(req.url).pathname);
    if (!route) return errorResponse(404, "NOT_FOUND", "対象が見つかりません。");

    const userId = await context(deps, req);
    if (!userId) return unauthenticated();

    try {
      // --- 作成 ---
      if (route.id === null) {
        if (req.method !== "POST") return methodNotAllowed();
        const body = await readJsonObject(req);
        if (!body) return invalidRequest();

        const text = validatePostBody(body.body);
        if (!text.ok) return invalid(text);
        const type = validatePostType(body.post_type);
        if (!type.ok) return invalid(type);
        const topic = validateTopicId(body.topic_id);
        if (!topic.ok) return invalid(topic);
        const mode = validateReactionMode(body.reaction_mode ?? "quiet_support");
        if (!mode.ok) return invalid(mode);
        const key = validateIdempotencyKey(req.headers.get("Idempotency-Key"));
        if (!key.ok) return invalid(key);

        const out = await checkedSave(
          deps,
          text.value,
          body.confirmed === true,
          (verified) =>
            deps.db.createPost({
              userId,
              postType: type.value,
              topicId: topic.value,
              body: verified,
              reactionMode: mode.value,
              idempotencyKey: key.value,
            }),
        );
        if ("blocked" in out) return out.blocked;
        return jsonResponse(201, { ...out.saved, support_notice: out.supportNotice });
      }

      const id = validateUuid(route.id, "id");
      if (!id.ok) return invalid(id);

      // --- 反応モード・受付状態 ---
      if (route.sub === "reaction-mode") {
        if (req.method !== "PATCH") return methodNotAllowed();
        const body = await readJsonObject(req);
        if (!body) return invalidRequest();
        const mode = validateReactionMode(body.reaction_mode);
        if (!mode.ok) return invalid(mode);
        const acceptance = validateAcceptance(body.comment_acceptance);
        if (!acceptance.ok) return invalid(acceptance);
        return jsonResponse(
          200,
          await deps.db.setReactionMode(userId, id.value, mode.value, acceptance.value),
        );
      }
      if (route.sub !== null) return errorResponse(404, "NOT_FOUND", "対象が見つかりません。");

      // --- 編集（本文のみ） ---
      if (req.method === "PATCH") {
        const body = await readJsonObject(req);
        if (!body) return invalidRequest();
        const text = validatePostBody(body.body);
        if (!text.ok) return invalid(text);
        const out = await checkedSave(
          deps,
          text.value,
          body.confirmed === true,
          (verified) => deps.db.updatePostBody(userId, id.value, verified),
        );
        if ("blocked" in out) return out.blocked;
        return jsonResponse(200, { ...out.saved, support_notice: out.supportNotice });
      }

      // --- 削除 ---
      if (req.method === "DELETE") {
        await deps.db.deletePost(userId, id.value);
        return jsonResponse(200, { deleted: true });
      }
      return methodNotAllowed();
    } catch (e) {
      return errorToResponse(e);
    }
  };
}

/** POST /comments（コメント・返信の作成）、PATCH /comments/{id}（編集）、DELETE /comments/{id}（削除） */
export function commentsHandler(deps: PostsDeps) {
  return async (req: Request): Promise<Response> => {
    const early = preflight(req);
    if (early) return early;

    const route = routeComments(new URL(req.url).pathname);
    if (!route) return errorResponse(404, "NOT_FOUND", "対象が見つかりません。");

    const userId = await context(deps, req);
    if (!userId) return unauthenticated();

    try {
      // --- 作成 ---
      if (route.id === null) {
        if (req.method !== "POST") return methodNotAllowed();
        const body = await readJsonObject(req);
        if (!body) return invalidRequest();

        const text = validateCommentBody(body.body);
        if (!text.ok) return invalid(text);
        const postId = validateUuid(body.post_id, "post_id");
        if (!postId.ok) return invalid(postId);
        let parentId: string | null = null;
        if (body.parent_comment_id !== undefined && body.parent_comment_id !== null) {
          const parent = validateUuid(body.parent_comment_id, "parent_comment_id");
          if (!parent.ok) return invalid(parent);
          parentId = parent.value;
        }
        const key = validateIdempotencyKey(req.headers.get("Idempotency-Key"));
        if (!key.ok) return invalid(key);

        const out = await checkedSave(
          deps,
          text.value,
          body.confirmed === true,
          (verified) =>
            deps.db.createComment({
              userId,
              postId: postId.value,
              parentCommentId: parentId,
              body: verified,
              idempotencyKey: key.value,
            }),
        );
        if ("blocked" in out) return out.blocked;
        return jsonResponse(201, { ...out.saved, support_notice: out.supportNotice });
      }

      const id = validateUuid(route.id, "id");
      if (!id.ok) return invalid(id);

      // --- 編集 ---
      if (req.method === "PATCH") {
        const body = await readJsonObject(req);
        if (!body) return invalidRequest();
        const text = validateCommentBody(body.body);
        if (!text.ok) return invalid(text);
        const out = await checkedSave(
          deps,
          text.value,
          body.confirmed === true,
          (verified) => deps.db.updateCommentBody(userId, id.value, verified),
        );
        if ("blocked" in out) return out.blocked;
        return jsonResponse(200, { ...out.saved, support_notice: out.supportNotice });
      }

      // --- 削除 ---
      if (req.method === "DELETE") {
        await deps.db.deleteComment(userId, id.value);
        return jsonResponse(200, { deleted: true });
      }
      return methodNotAllowed();
    } catch (e) {
      return errorToResponse(e);
    }
  };
}
