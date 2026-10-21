import { guarded } from "../_shared/http.ts";
import { commentsHandler } from "../_shared/posts/handlers.ts";
import { createPostsDeps } from "../_shared/posts/wiring.ts";

Deno.serve(guarded(commentsHandler(createPostsDeps())));
