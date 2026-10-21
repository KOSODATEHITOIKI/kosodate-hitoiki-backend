import { guarded } from "../_shared/http.ts";
import { postsHandler } from "../_shared/posts/handlers.ts";
import { createPostsDeps } from "../_shared/posts/wiring.ts";

Deno.serve(guarded(postsHandler(createPostsDeps())));
