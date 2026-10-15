import { moderationHandler } from "../_shared/reports/handlers.ts";
import { createReportsDeps } from "../_shared/reports/wiring.ts";

Deno.serve(moderationHandler(createReportsDeps()));
