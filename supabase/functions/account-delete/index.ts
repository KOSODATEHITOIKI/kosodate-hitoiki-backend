import { accountDeleteHandler } from "../_shared/account/handlers.ts";
import { createAccountDeps } from "../_shared/account/wiring.ts";

Deno.serve(accountDeleteHandler(createAccountDeps()));
