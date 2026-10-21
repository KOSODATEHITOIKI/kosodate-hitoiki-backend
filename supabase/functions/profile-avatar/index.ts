import { guarded } from "../_shared/http.ts";
import { avatarHandler } from "../_shared/profile/handlers.ts";
import { createProfileDeps } from "../_shared/profile/wiring.ts";

Deno.serve(guarded(avatarHandler(createProfileDeps())));
