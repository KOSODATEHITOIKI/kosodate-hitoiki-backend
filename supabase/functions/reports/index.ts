import { guarded } from "../_shared/http.ts";
import { reportsHandler } from "../_shared/reports/handlers.ts";
import { createReportsDeps } from "../_shared/reports/wiring.ts";

Deno.serve(guarded(reportsHandler(createReportsDeps())));
