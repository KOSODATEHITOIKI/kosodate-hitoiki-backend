import { guarded } from "../_shared/http.ts";
import { moderationHandler } from "../_shared/reports/handlers.ts";
import { createReportsDeps } from "../_shared/reports/wiring.ts";

Deno.serve(guarded(moderationHandler(createReportsDeps())));
