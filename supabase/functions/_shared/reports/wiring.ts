import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { verifiedUser } from "../auth.ts";
import { type ReportsDb, type ReportsDeps, SETTING_KEYS, toReportsError } from "./types.ts";

/**
 * 実際のSupabase（service_role）へ接続する配線。ロジックは handlers.ts とDB関数にある。
 * 認証保証レベル（aal）は、Supabase Authが検証したトークンのクレームから読む
 * （クライアントの自己申告ではない）。
 */
export function createReportsDeps(): ReportsDeps {
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );

  async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
    const { data, error } = await admin.rpc(fn, args);
    if (error) throw toReportsError(error);
    return data as T;
  }

  const db: ReportsDb = {
    createReport: (a) =>
      rpc("create_report", {
        p_reporter_id: a.reporterId,
        p_target_type: a.targetType,
        p_target_id: a.targetId,
        p_reason: a.reason,
        p_detail: a.detail,
      }),
    isRegisteredAdmin: async (userId) => {
      const { data, error } = await admin.from("admin_users").select("user_id")
        .eq("user_id", userId).maybeSingle();
      if (error) throw toReportsError(error);
      return data !== null;
    },
    getSettings: async () => {
      const { data, error } = await admin.from("app_settings").select("key, value")
        .in("key", [...SETTING_KEYS]);
      if (error) throw toReportsError(error);
      return Object.fromEntries((data ?? []).map((r) => [r.key, r.value]));
    },
    setSetting: async (adminId, key, value) => {
      await rpc("set_app_setting", { p_admin_id: adminId, p_key: key, p_value: value });
    },
    applyModeration: (a) =>
      rpc("moderation_apply", {
        p_admin_id: a.adminId,
        p_target_type: a.targetType,
        p_target_id: a.targetId,
        p_action: a.action,
        p_reason: a.reason,
      }),
  };

  return {
    async authenticate(req) {
      const user = await verifiedUser(admin, req);
      if (!user) return null;
      const aal = user.claims.aal;
      return { userId: user.userId, aal: typeof aal === "string" ? aal : "" };
    },
    db,
  };
}
