import { commentsHandler } from "../_shared/posts/handlers.ts";
import { createPostsDeps } from "../_shared/posts/wiring.ts";

Deno.serve(commentsHandler(createPostsDeps()));
