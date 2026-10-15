import { pushDispatchHandler } from "../_shared/push/handlers.ts";
import { createPushDeps } from "../_shared/push/wiring.ts";

Deno.serve(pushDispatchHandler(createPushDeps()));
