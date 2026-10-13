import { updateProfileHandler } from "../_shared/profile/handlers.ts";
import { createProfileDeps } from "../_shared/profile/wiring.ts";

Deno.serve(updateProfileHandler(createProfileDeps()));
