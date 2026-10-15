import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { createFcmSender, parseServiceAccount } from "./fcm.ts";
import type { PushDb, PushDeps, PushJob, PushSender } from "./types.ts";

/** 実際のSupabase（service_role）とFCMへ接続する配線。ロジックは handlers.ts・fcm.ts とDB関数にある。 */
export function createPushDeps(): PushDeps {
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );

  const db: PushDb = {
    claim: async (limit) => {
      const { data, error } = await admin.rpc("claim_push_deliveries", { p_limit: limit });
      if (error) throw new Error("database error");
      return (data ?? []).map((r: Record<string, string>): PushJob => ({
        deliveryId: r.delivery_id,
        notificationId: r.notification_id,
        notificationType: r.notification_type,
        platform: r.platform,
        deviceToken: r.device_token,
      }));
    },
    finish: async (deliveryId, outcome, errorCode) => {
      const { error } = await admin.rpc("finish_push_delivery", {
        p_delivery_id: deliveryId,
        p_outcome: outcome,
        p_error: errorCode ?? null,
      });
      if (error) throw new Error("database error");
    },
  };

  const account = parseServiceAccount(Deno.env.get("FCM_SERVICE_ACCOUNT_JSON"));
  const unconfigured: PushSender = {
    send: () => Promise.resolve({ outcome: "retry", errorCode: "NOT_CONFIGURED" }),
  };

  return {
    db,
    sender: account ? createFcmSender(account) : unconfigured,
    dispatchSecret: Deno.env.get("PUSH_DISPATCH_SECRET"),
    senderConfigured: account !== null,
  };
}
