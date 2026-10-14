import { type ModerationScores, ModerationUnavailableError } from "../moderation/types.ts";
import { type PostsDb, type PostsDeps, RuleError } from "./types.ts";

export const USER_ID = "00000000-0000-0000-0000-0000000000a1";
export const POST_ID = "00000000-0000-0000-0000-0000000000b1";
export const COMMENT_ID = "00000000-0000-0000-0000-0000000000c1";

export interface Fake {
  deps: PostsDeps;
  calls: {
    createPost: Parameters<PostsDb["createPost"]>[0][];
    updatePostBody: { postId: string; body: string }[];
    deletePost: string[];
    setReactionMode: { mode: string; acceptance: string | null }[];
    createComment: Parameters<PostsDb["createComment"]>[0][];
    updateCommentBody: { commentId: string; body: string }[];
    deleteComment: string[];
    moderated: string[];
  };
}

export function makeFake(options: {
  loggedIn?: boolean;
  scores?: ModerationScores;
  moderationDown?: boolean;
  /** DB関数が返す業務ルール違反（内部コード）。 */
  rule?: string;
  ruleMessage?: string;
  /** DB関数が想定外のエラーを返す。 */
  unexpected?: boolean;
} = {}): Fake {
  const fake: Fake = {
    calls: {
      createPost: [],
      updatePostBody: [],
      deletePost: [],
      setReactionMode: [],
      createComment: [],
      updateCommentBody: [],
      deleteComment: [],
      moderated: [],
    },
    deps: undefined as unknown as PostsDeps,
  };
  const maybeFail = () => {
    if (options.rule) throw new RuleError(options.rule, options.ruleMessage);
    if (options.unexpected) throw new Error("boom with secret 本文");
  };

  fake.deps = {
    authenticate: () => Promise.resolve(options.loggedIn === false ? null : USER_ID),
    moderation: {
      moderate: (text) => {
        fake.calls.moderated.push(text);
        return options.moderationDown
          ? Promise.reject(new ModerationUnavailableError())
          : Promise.resolve(options.scores ?? {});
      },
    },
    db: {
      createPost: (a) => {
        maybeFail();
        fake.calls.createPost.push(a);
        return Promise.resolve({ id: POST_ID, created_at: "2026-10-14T00:00:00Z" });
      },
      updatePostBody: (_u, postId, body) => {
        maybeFail();
        fake.calls.updatePostBody.push({ postId, body });
        return Promise.resolve({ id: postId, edited_at: "2026-10-14T00:00:01Z" });
      },
      deletePost: (_u, postId) => {
        maybeFail();
        fake.calls.deletePost.push(postId);
        return Promise.resolve();
      },
      setReactionMode: (_u, _p, mode, acceptance) => {
        maybeFail();
        fake.calls.setReactionMode.push({ mode, acceptance });
        return Promise.resolve({
          reaction_mode: mode,
          comment_acceptance: mode === "want_comments" ? acceptance ?? "open" : null,
        });
      },
      createComment: (a) => {
        maybeFail();
        fake.calls.createComment.push(a);
        return Promise.resolve({ id: COMMENT_ID, created_at: "2026-10-14T00:00:00Z" });
      },
      updateCommentBody: (_u, commentId, body) => {
        maybeFail();
        fake.calls.updateCommentBody.push({ commentId, body });
        return Promise.resolve({ id: commentId, edited_at: "2026-10-14T00:00:01Z" });
      },
      deleteComment: (_u, commentId) => {
        maybeFail();
        fake.calls.deleteComment.push(commentId);
        return Promise.resolve();
      },
    },
  };
  return fake;
}

export function req(
  method: string,
  path: string,
  body?: unknown,
  headers: Record<string, string> = {},
): Request {
  return new Request(`http://localhost${path}`, {
    method,
    headers: { "Content-Type": "application/json", Authorization: "Bearer token", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}
