import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { type ReportsDb, type ReportsDeps, toReportsError } from "./types.ts";

/** JWTの本体（payload）を読む。署名の検証は getUser で済ませたトークンにだけ使う。 */
function readPayload(token: string): Record<string, unknown> {
  const part = token.split(".")[1] ?? "";
  const base64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(
    Math.ceil(part.length / 4) * 4,
    "=",
  );
  try {
    const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return {};
  }
}

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
      const match = /^Bearer (.+)$/i.exec(req.headers.get("Authorization") ?? "");
      if (!match) return null;
      const { data, error } = await admin.auth.getUser(match[1]);
      if (error || !data.user) return null;
      const aal = readPayload(match[1]).aal;
      return { userId: data.user.id, aal: typeof aal === "string" ? aal : "" };
    },
    db,
  };
}
