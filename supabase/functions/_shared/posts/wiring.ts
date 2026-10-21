import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { verifiedUser } from "../auth.ts";
import { callModeration } from "../moderation/openai.ts";
import { type PostsDb, type PostsDeps, toRuleError } from "./types.ts";

/**
 * 実際のSupabase（service_role）へ接続する配線。ロジックは handlers.ts とDB関数にあり、
 * ここは薄い変換だけにしてテストはフェイクで行う。
 * 特権キーはEdge Functionsの環境変数にだけ置き、アプリへは配布しない。
 * エラーはSQLSTATEとコード・既知の文言だけを取り出し、生のメッセージ（本文を含みうる）は捨てる。
 */
export function createPostsDeps(): PostsDeps {
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  const openAi = { apiKey: Deno.env.get("OPENAI_API_KEY") };

  async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
    const { data, error } = await admin.rpc(fn, args);
    if (error) throw toRuleError(error);
    return data as T;
  }

  const db: PostsDb = {
    preflight: async (userId, kind, idempotencyKey) => {
      await rpc("preflight_write", {
        p_user_id: userId,
        p_kind: kind,
        p_idempotency_key: idempotencyKey ?? null,
      });
    },
    replayResponse: (userId, kind, key) =>
      rpc("replay_idempotent_response", { p_user_id: userId, p_kind: kind, p_key: key }),
    rememberSupportNotice: async (userId, kind, key) => {
      await rpc("remember_support_notice", { p_user_id: userId, p_kind: kind, p_key: key });
    },
    createPost: (a) =>
      rpc("create_post", {
        p_user_id: a.userId,
        p_post_type: a.postType,
        p_topic_id: a.topicId,
        p_body: a.body,
        p_reaction_mode: a.reactionMode,
        p_idempotency_key: a.idempotencyKey,
      }),
    updatePostBody: (userId, postId, body) =>
      rpc("update_post_body", { p_user_id: userId, p_post_id: postId, p_body: body }),
    deletePost: async (userId, postId) => {
      await rpc("delete_post", { p_user_id: userId, p_post_id: postId });
    },
    setReactionMode: (userId, postId, mode, acceptance) =>
      rpc("set_post_reaction_mode", {
        p_user_id: userId,
        p_post_id: postId,
        p_mode: mode,
        p_acceptance: acceptance,
      }),
    createComment: (a) =>
      rpc("create_comment", {
        p_user_id: a.userId,
        p_post_id: a.postId,
        p_parent_comment_id: a.parentCommentId,
        p_body: a.body,
        p_idempotency_key: a.idempotencyKey,
      }),
    updateCommentBody: (userId, commentId, body) =>
      rpc("update_comment_body", { p_user_id: userId, p_comment_id: commentId, p_body: body }),
    deleteComment: async (userId, commentId) => {
      await rpc("delete_comment", { p_user_id: userId, p_comment_id: commentId });
    },
    setReaction: (userId, postId, reactionTypeId) =>
      rpc("set_reaction", {
        p_user_id: userId,
        p_post_id: postId,
        p_reaction_type_id: reactionTypeId,
      }),
    removeReaction: (userId, postId) =>
      rpc("remove_reaction", { p_user_id: userId, p_post_id: postId }),
  };

  return {
    async authenticate(req) {
      return (await verifiedUser(admin, req))?.userId ?? null;
    },
    moderation: { moderate: (text) => callModeration(text, openAi) },
    db,
  };
}
