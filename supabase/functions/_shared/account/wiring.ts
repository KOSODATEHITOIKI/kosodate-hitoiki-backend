import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { type AccountDb, type AccountDeps, type AccountStorage, toAccountError } from "./types.ts";

/** 実際のSupabase（service_role）へ接続する配線。ロジックは handlers.ts とDB関数にある。 */
export function createAccountDeps(): AccountDeps {
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );

  const db: AccountDb = {
    isOperator: async (userId) => {
      const { data, error } = await admin.from("admin_users").select("user_id")
        .eq("user_id", userId).maybeSingle();
      if (error) throw toAccountError(error);
      return data !== null;
    },
    withdraw: async (userId) => {
      const { data, error } = await admin.rpc("withdraw_account", { p_user_id: userId });
      if (error) throw toAccountError(error);
      return (data as { status: "deleted" | "already_deleted" }).status;
    },
  };

  const avatars = admin.storage.from("avatars");
  const storage: AccountStorage = {
    // 画像は <user_id>/<ファイル名>。フォルダ内を数えて、残らないようにすべて消す。
    removeAllFor: async (userId) => {
      for (let round = 0; round < 20; round++) {
        const { data, error } = await avatars.list(userId, { limit: 100 });
        if (error) throw new Error("storage error");
        if (!data || data.length === 0) return;
        const { error: rmError } = await avatars.remove(data.map((f) => `${userId}/${f.name}`));
        if (rmError) throw new Error("storage error");
      }
      throw new Error("storage error"); // 想定外に多い。残したまま退会させない
    },
  };

  return {
    async authenticate(req) {
      const match = /^Bearer (.+)$/i.exec(req.headers.get("Authorization") ?? "");
      if (!match) return null;
      const { data, error } = await admin.auth.getUser(match[1]);
      if (error || !data.user) return null;
      return { userId: data.user.id, lastSignInAt: data.user.last_sign_in_at ?? null };
    },
    db,
    storage,
  };
}
