import { storageCleanupHandler } from "../_shared/profile/cleanup_handler.ts";
import { drainPendingDeletions } from "../_shared/profile/handlers.ts";
import { createJobSecretVerifier } from "../_shared/job_secret_wiring.ts";
import { createProfileDeps } from "../_shared/profile/wiring.ts";

const deps = createProfileDeps();

Deno.serve(storageCleanupHandler({
  verifyJobSecret: createJobSecretVerifier(),
  drain: (limit) => drainPendingDeletions(deps, limit),
}));
