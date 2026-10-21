import { guarded } from "../_shared/http.ts";
import { accountDeleteHandler } from "../_shared/account/handlers.ts";
import { createAccountDeps } from "../_shared/account/wiring.ts";

Deno.serve(guarded(accountDeleteHandler(createAccountDeps())));
