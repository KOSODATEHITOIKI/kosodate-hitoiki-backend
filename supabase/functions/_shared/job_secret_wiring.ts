import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import type { JobSecretVerifier } from "./internal_auth.ts";

/** 内部ジョブの秘密を、DB（Vault）に問い合わせて確かめる。service_roleだけが呼べる関数を使う。 */
export function createJobSecretVerifier(): JobSecretVerifier {
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  return async (given) => {
    const { data, error } = await admin.rpc("job_secret_valid", { p_given: given });
    if (error) throw new Error("database error");
    return data === true;
  };
}
