import { storageCleanupHandler } from "../_shared/profile/cleanup_handler.ts";
import { drainPendingDeletions } from "../_shared/profile/handlers.ts";
import { createProfileDeps } from "../_shared/profile/wiring.ts";

const deps = createProfileDeps();

Deno.serve(storageCleanupHandler({
  jobSecret: Deno.env.get("INTERNAL_JOB_SECRET"),
  drain: (limit) => drainPendingDeletions(deps, limit),
}));
