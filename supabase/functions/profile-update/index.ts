import { guarded } from "../_shared/http.ts";
import { updateProfileHandler } from "../_shared/profile/handlers.ts";
import { createProfileDeps } from "../_shared/profile/wiring.ts";

Deno.serve(guarded(updateProfileHandler(createProfileDeps())));
