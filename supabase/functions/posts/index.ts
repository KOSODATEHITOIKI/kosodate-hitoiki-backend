import { postsHandler } from "../_shared/posts/handlers.ts";
import { createPostsDeps } from "../_shared/posts/wiring.ts";

Deno.serve(postsHandler(createPostsDeps()));
