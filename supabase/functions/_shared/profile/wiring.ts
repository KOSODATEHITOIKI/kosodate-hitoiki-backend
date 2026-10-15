import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { callModeration, callModerationImage } from "../moderation/openai.ts";
import { DbError, type ProfileDeps, toDbError } from "./types.ts";

/**
 * 実際のSupabase（service_role）へ接続する配線。ロジックは handlers.ts にあり、
 * ここは薄い変換だけにしてテストはフェイクで行う。
 * 特権キーはEdge Functionsの環境変数にだけ置き、アプリへは配布しない。
 * エラーはSQLSTATEコードだけを取り出し、生のメッセージ（本文を含みうる）は捨てる。
 */
export function createProfileDeps(): ProfileDeps {
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  const openAi = { apiKey: Deno.env.get("OPENAI_API_KEY") };
  const avatars = admin.storage.from("avatars");

  return {
    async authenticate(req) {
      const match = /^Bearer (.+)$/i.exec(req.headers.get("Authorization") ?? "");
      if (!match) return null;
      const { data, error } = await admin.auth.getUser(match[1]);
      return error || !data.user ? null : data.user.id;
    },

    moderation: { moderate: (text) => callModeration(text, openAi) },
    imageModeration: {
      moderateImage: (bytes, mimeType) => callModerationImage(bytes, mimeType, openAi),
    },

    db: {
      async preflight(userId, kind) {
        const { error } = await admin.rpc("preflight_write", { p_user_id: userId, p_kind: kind });
        if (error) throw toDbError(error);
      },

      async claimStorageDeletions(limit) {
        const { data, error } = await admin.rpc("claim_storage_deletions", { p_limit: limit });
        if (error) throw toDbError(error);
        return (data ?? []).map((r: { path: string }) => r.path);
      },

      async finishStorageDeletion(path, ok, errorCode) {
        const { error } = await admin.rpc("finish_storage_deletion", {
          p_bucket: "avatars",
          p_path: path,
          p_ok: ok,
          p_error: errorCode ?? null,
        });
        if (error) throw toDbError(error);
      },

      async queueStorageDeletion(path) {
        const { error } = await admin.from("pending_storage_deletions").upsert(
          { bucket: "avatars", path },
          { onConflict: "bucket,path", ignoreDuplicates: true },
        );
        if (error) throw toDbError(error);
      },

      async createProfile(a) {
        const { data, error } = await admin.rpc("create_profile", {
          p_user_id: a.userId,
          p_nickname: a.nickname,
          p_bio: a.bio,
          p_child_age_range: a.childAgeRange,
          p_icon_key: a.iconKey,
          p_terms_version: a.termsVersion,
        });
        if (error) throw toDbError(error);
        return data as "created" | "exists" | "conflict";
      },

      async changeNickname(userId, nickname) {
        const { data, error } = await admin.from("profiles").update({ nickname }).eq("id", userId)
          .select("id");
        if (error) throw toDbError(error);
        if (!data || data.length === 0) throw new DbError("NOT_FOUND");
      },

      async updateProfile(userId, patch) {
        // イラストを選ぶときは、アップロード画像を外す（どちらか一方、DBのcheck制約）。
        const values = patch.icon_key ? { ...patch, avatar_path: null } : patch;
        const { data, error } = await admin.from("profiles").update(values).eq("id", userId)
          .select("id");
        if (error) throw toDbError(error);
        if (!data || data.length === 0) throw new DbError("NOT_FOUND");
      },

      async getAvatarPath(userId) {
        const { data, error } = await admin.from("profiles").select("avatar_path").eq("id", userId)
          .maybeSingle();
        if (error) throw toDbError(error);
        return data?.avatar_path ?? null;
      },

      async setAvatarPath(userId, path) {
        const values = path ? { avatar_path: path, icon_key: null } : { avatar_path: null };
        const { data, error } = await admin.from("profiles").update(values).eq("id", userId)
          .select("id");
        if (error) throw toDbError(error);
        if (!data || data.length === 0) throw new DbError("NOT_FOUND");
      },
    },

    storage: {
      async upload(path, bytes, contentType) {
        const { error } = await avatars.upload(path, bytes, { contentType, upsert: false });
        if (error) throw new DbError("STORAGE");
      },
      async remove(path) {
        const { error } = await avatars.remove([path]);
        if (error) throw new DbError("STORAGE");
      },
    },
  };
}
