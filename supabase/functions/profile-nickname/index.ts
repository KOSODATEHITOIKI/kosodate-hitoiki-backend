import { changeNicknameHandler } from "../_shared/profile/handlers.ts";
import { createProfileDeps } from "../_shared/profile/wiring.ts";

Deno.serve(changeNicknameHandler(createProfileDeps()));
