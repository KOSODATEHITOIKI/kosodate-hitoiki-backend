import { assert, assertEquals } from "@std/assert";
import { commentsHandler, postsHandler, routeComments, routePosts } from "./handlers.ts";
import { COMMENT_ID, makeFake, POST_ID, req, USER_ID } from "./test_helpers.ts";
import { RuleError, toRuleError } from "./types.ts";

const validPost = { post_type: "guchi", body: "今日は大変だった", reaction_mode: "quiet_support" };

async function errorBody(res: Response) {
  return (await res.json()).error as { code: string; message: string; details?: unknown };
}

// --- ルーティング ---

Deno.test("ルーティング：関数名より前の接頭辞は無視し、パスで振り分ける", () => {
  assertEquals(routePosts("/posts"), { id: null, sub: null });
  assertEquals(routePosts("/functions/v1/posts"), { id: null, sub: null });
  assertEquals(routePosts(`/posts/${POST_ID}`), { id: POST_ID, sub: null });
  assertEquals(routePosts(`/functions/v1/posts/${POST_ID}/reaction-mode`), {
    id: POST_ID,
    sub: "reaction-mode",
  });
  assertEquals(routePosts("/other"), null);
  assertEquals(routeComments("/comments"), { id: null });
  assertEquals(routeComments(`/comments/${COMMENT_ID}`), { id: COMMENT_ID });
  assertEquals(routeComments("/comments/a/b"), null);
});

// --- 投稿の作成 ---

Deno.test("投稿作成：未ログインは 401 でDBにも外部APIにも触れない", async () => {
  const f = makeFake({ loggedIn: false });
  const res = await postsHandler(f.deps)(req("POST", "/posts", validPost));
  assertEquals(res.status, 401);
  assertEquals(f.calls.createPost.length, 0);
  assertEquals(f.calls.moderated.length, 0);
});

Deno.test("投稿作成：成功すると 201。チェックした本文（前後の空白を除いたもの）がそのまま保存される", async () => {
  const f = makeFake();
  const res = await postsHandler(f.deps)(
    req("POST", "/posts", { ...validPost, body: "  今日は大変だった  " }, {
      "Idempotency-Key": "key-1",
    }),
  );
  assertEquals(res.status, 201);
  assertEquals(await res.json(), {
    id: POST_ID,
    created_at: "2026-10-14T00:00:00Z",
    support_notice: false,
  });
  assertEquals(f.calls.createPost, [{
    userId: USER_ID,
    postType: "guchi",
    topicId: null,
    body: "今日は大変だった",
    reactionMode: "quiet_support",
    idempotencyKey: "key-1",
  }]);
  assertEquals(f.calls.moderated, ["今日は大変だった"]);
});

Deno.test("投稿作成：反応モードの省略は「ただ聞いてほしい」", async () => {
  const f = makeFake();
  await postsHandler(f.deps)(req("POST", "/posts", { post_type: "kotsu", body: "コツです" }));
  assertEquals(f.calls.createPost[0].reactionMode, "quiet_support");
});

Deno.test("投稿作成：入力の不備は 422 でDBに触れない", async () => {
  const cases: unknown[] = [
    { ...validPost, body: "" },
    { ...validPost, body: "   " },
    { ...validPost, body: "あ".repeat(1001) },
    { ...validPost, post_type: "x" },
    { ...validPost, topic_id: "3" },
    { ...validPost, reaction_mode: "x" },
  ];
  for (const body of cases) {
    const f = makeFake();
    const res = await postsHandler(f.deps)(req("POST", "/posts", body));
    assertEquals(res.status, 422, JSON.stringify(body).slice(0, 40));
    assertEquals((await errorBody(res)).code, "VALIDATION_FAILED");
    assertEquals(f.calls.createPost.length, 0);
  }
});

Deno.test("投稿作成：不正なIdempotency-Keyは 422", async () => {
  const f = makeFake();
  const res = await postsHandler(f.deps)(
    req("POST", "/posts", validPost, { "Idempotency-Key": "bad key!" }),
  );
  assertEquals(res.status, 422);
});

Deno.test("投稿作成：個人情報を含む本文は 422 で保存せず、外部APIにも送らない", async () => {
  const f = makeFake();
  const res = await postsHandler(f.deps)(
    req("POST", "/posts", { ...validPost, body: "連絡は090-1234-5678まで" }),
  );
  assertEquals(res.status, 422);
  assertEquals((await errorBody(res)).code, "MODERATION_REJECTED");
  assertEquals(f.calls.createPost.length, 0);
  assertEquals(f.calls.moderated.length, 0);
});

Deno.test("投稿作成：境界域は 409。confirmed=true の再送で保存される。明確な攻撃は覆らない", async () => {
  const f = makeFake({ scores: { harassment: 0.6 } });
  const first = await postsHandler(f.deps)(req("POST", "/posts", validPost));
  assertEquals(first.status, 409);
  assertEquals((await errorBody(first)).code, "MODERATION_CONFIRM_REQUIRED");
  assertEquals(f.calls.createPost.length, 0);
  const second = await postsHandler(f.deps)(
    req("POST", "/posts", { ...validPost, confirmed: true }),
  );
  assertEquals(second.status, 201);

  const g = makeFake({ scores: { harassment: 0.95 } });
  const rejected = await postsHandler(g.deps)(
    req("POST", "/posts", { ...validPost, confirmed: true }),
  );
  assertEquals(rejected.status, 422);
  assertEquals(g.calls.createPost.length, 0);
});

Deno.test("投稿作成：危害のほのめかしは保存を許可し、本人にだけ support_notice を返す", async () => {
  const f = makeFake({ scores: { "self-harm": 0.9 } });
  const res = await postsHandler(f.deps)(req("POST", "/posts", validPost));
  assertEquals(res.status, 201);
  assertEquals((await res.json()).support_notice, true);
  assertEquals(f.calls.createPost.length, 1);
});

Deno.test("投稿作成：外部APIの障害は 503 で保存しない", async () => {
  const f = makeFake({ moderationDown: true });
  const res = await postsHandler(f.deps)(req("POST", "/posts", validPost));
  assertEquals(res.status, 503);
  assertEquals((await errorBody(res)).code, "MODERATION_UNAVAILABLE");
  assertEquals(f.calls.createPost.length, 0);
});

Deno.test("投稿作成：利用停止中・プロフィール未登録は 403（理由つき）", async () => {
  for (
    const [rule, reason] of [["RESTRICTED", "restricted"], ["PROFILE_REQUIRED", "profile_required"]]
  ) {
    const f = makeFake({ rule });
    const res = await postsHandler(f.deps)(req("POST", "/posts", validPost));
    assertEquals(res.status, 403);
    const e = await errorBody(res);
    assertEquals(e.code, "FORBIDDEN");
    assertEquals((e.details as { reason: string }).reason, reason);
  }
});

Deno.test("想定外のエラーは 500。本文・内部の文言をレスポンスに含めない", async () => {
  const f = makeFake({ unexpected: true });
  const res = await postsHandler(f.deps)(req("POST", "/posts", validPost));
  assertEquals(res.status, 500);
  const text = JSON.stringify(await res.json());
  assert(!text.includes("secret") && !text.includes("今日は大変だった"));
});

// --- 投稿の編集・削除・反応モード ---

Deno.test("投稿編集：本文を送信前チェックにかけてから更新する。他人は 403、存在しなければ 404", async () => {
  const f = makeFake();
  const ok = await postsHandler(f.deps)(req("PATCH", `/posts/${POST_ID}`, { body: "書き直した" }));
  assertEquals(ok.status, 200);
  assertEquals(f.calls.updatePostBody, [{ postId: POST_ID, body: "書き直した" }]);
  assertEquals(f.calls.moderated, ["書き直した"]);

  const ng = makeFake();
  const blocked = await postsHandler(ng.deps)(
    req("PATCH", `/posts/${POST_ID}`, { body: "メールは taro@example.com" }),
  );
  assertEquals(blocked.status, 422);
  assertEquals(ng.calls.updatePostBody.length, 0);

  for (const [rule, status] of [["FORBIDDEN", 403], ["NOT_FOUND", 404]] as const) {
    const g = makeFake({ rule });
    const res = await postsHandler(g.deps)(req("PATCH", `/posts/${POST_ID}`, { body: "本文" }));
    assertEquals(res.status, status);
  }
});

Deno.test("投稿編集：本文のみ。種類・話題・反応モードは変更できない（無視される）", async () => {
  const f = makeFake();
  await postsHandler(f.deps)(
    req("PATCH", `/posts/${POST_ID}`, {
      body: "本文",
      post_type: "kotsu",
      topic_id: 2,
      reaction_mode: "want_comments",
    }),
  );
  assertEquals(f.calls.updatePostBody, [{ postId: POST_ID, body: "本文" }]);
  assertEquals(f.calls.setReactionMode.length, 0);
});

Deno.test("投稿の削除：本人の削除は 200、他人は 403", async () => {
  const f = makeFake();
  const ok = await postsHandler(f.deps)(req("DELETE", `/posts/${POST_ID}`));
  assertEquals(ok.status, 200);
  assertEquals(f.calls.deletePost, [POST_ID]);
  const g = makeFake({ rule: "FORBIDDEN" });
  assertEquals((await postsHandler(g.deps)(req("DELETE", `/posts/${POST_ID}`))).status, 403);
});

Deno.test("反応モード：変更できる。不正な値・形式は 422、他人は 403", async () => {
  const f = makeFake();
  const ok = await postsHandler(f.deps)(
    req("PATCH", `/posts/${POST_ID}/reaction-mode`, {
      reaction_mode: "want_comments",
      comment_acceptance: "closed",
    }),
  );
  assertEquals(ok.status, 200);
  assertEquals(await ok.json(), { reaction_mode: "want_comments", comment_acceptance: "closed" });

  for (
    const body of [{ reaction_mode: "x" }, {
      reaction_mode: "want_comments",
      comment_acceptance: "x",
    }]
  ) {
    const g = makeFake();
    assertEquals(
      (await postsHandler(g.deps)(req("PATCH", `/posts/${POST_ID}/reaction-mode`, body))).status,
      422,
    );
    assertEquals(g.calls.setReactionMode.length, 0);
  }
  const h = makeFake({ rule: "FORBIDDEN" });
  assertEquals(
    (await postsHandler(h.deps)(
      req("PATCH", `/posts/${POST_ID}/reaction-mode`, { reaction_mode: "quiet_support" }),
    )).status,
    403,
  );
});

Deno.test("投稿：IDの形式が不正なら 422、メソッドが違えば 405、プリフライトは 204", async () => {
  const f = makeFake();
  assertEquals(
    (await postsHandler(f.deps)(req("PATCH", "/posts/not-a-uuid", { body: "本文" }))).status,
    422,
  );
  assertEquals((await postsHandler(f.deps)(req("GET", "/posts"))).status, 405);
  assertEquals((await postsHandler(f.deps)(req("PUT", `/posts/${POST_ID}`, {}))).status, 405);
  assertEquals(
    (await postsHandler(f.deps)(new Request("http://localhost/posts", { method: "OPTIONS" })))
      .status,
    204,
  );
  assertEquals((await postsHandler(f.deps)(req("POST", "/nothing", {}))).status, 404);
});

// --- コメント・返信 ---

const validComment = {
  post_id: POST_ID,
  parent_comment_id: null,
  body: "わかります、私も同じです",
};

Deno.test("コメント作成：未ログインは 401", async () => {
  const f = makeFake({ loggedIn: false });
  assertEquals((await commentsHandler(f.deps)(req("POST", "/comments", validComment))).status, 401);
  assertEquals(f.calls.createComment.length, 0);
});

Deno.test("コメント作成：成功すると 201。親コメント・Idempotency-Keyも渡る", async () => {
  const f = makeFake();
  const res = await commentsHandler(f.deps)(
    req("POST", "/comments", { ...validComment, parent_comment_id: COMMENT_ID }, {
      "Idempotency-Key": "k-1",
    }),
  );
  assertEquals(res.status, 201);
  assertEquals(f.calls.createComment, [{
    userId: USER_ID,
    postId: POST_ID,
    parentCommentId: COMMENT_ID,
    body: "わかります、私も同じです",
    idempotencyKey: "k-1",
  }]);
});

Deno.test("コメント作成：500文字超・空・IDの不備は 422", async () => {
  for (
    const body of [
      { ...validComment, body: "あ".repeat(501) },
      { ...validComment, body: "  " },
      { ...validComment, post_id: "x" },
      { ...validComment, parent_comment_id: "x" },
    ]
  ) {
    const f = makeFake();
    assertEquals((await commentsHandler(f.deps)(req("POST", "/comments", body))).status, 422);
    assertEquals(f.calls.createComment.length, 0);
  }
});

Deno.test("コメント作成：受付終了・ブロック・利用停止は 403（理由つき）、投稿がなければ 404", async () => {
  for (
    const [rule, reason] of [
      ["COMMENTS_CLOSED", "comments_closed"],
      ["BLOCKED", "unavailable"],
      ["RESTRICTED", "restricted"],
    ]
  ) {
    const f = makeFake({ rule });
    const res = await commentsHandler(f.deps)(req("POST", "/comments", validComment));
    assertEquals(res.status, 403);
    assertEquals(((await errorBody(res)).details as { reason: string }).reason, reason);
  }
  const g = makeFake({ rule: "NOT_FOUND" });
  assertEquals((await commentsHandler(g.deps)(req("POST", "/comments", validComment))).status, 404);
});

Deno.test("コメント作成：返信への返信など、階層の違反は 422（DBの文言をそのまま通す）", async () => {
  const f = makeFake({ rule: "VALIDATION_FAILED", ruleMessage: "返信への返信はできません" });
  const res = await commentsHandler(f.deps)(
    req("POST", "/comments", { ...validComment, parent_comment_id: COMMENT_ID }),
  );
  assertEquals(res.status, 422);
  assertEquals((await errorBody(res)).message, "返信への返信はできません");
});

Deno.test("コメント作成：個人情報は 422、外部APIの障害は 503 で、どちらも保存しない", async () => {
  const f = makeFake();
  const ng = await commentsHandler(f.deps)(
    req("POST", "/comments", { ...validComment, body: "090-1234-5678に連絡して" }),
  );
  assertEquals(ng.status, 422);
  const g = makeFake({ moderationDown: true });
  assertEquals((await commentsHandler(g.deps)(req("POST", "/comments", validComment))).status, 503);
  assertEquals(f.calls.createComment.length + g.calls.createComment.length, 0);
});

Deno.test("コメント編集・削除：本人は可。他人は 403、削除済みは 404", async () => {
  const f = makeFake();
  const edit = await commentsHandler(f.deps)(
    req("PATCH", `/comments/${COMMENT_ID}`, { body: "書き直した" }),
  );
  assertEquals(edit.status, 200);
  assertEquals(f.calls.updateCommentBody, [{ commentId: COMMENT_ID, body: "書き直した" }]);
  assertEquals(f.calls.moderated, ["書き直した"]); // 編集時も送信前チェック

  const del = await commentsHandler(f.deps)(req("DELETE", `/comments/${COMMENT_ID}`));
  assertEquals(del.status, 200);
  assertEquals(f.calls.deleteComment, [COMMENT_ID]);

  for (const [rule, status] of [["FORBIDDEN", 403], ["NOT_FOUND", 404]] as const) {
    const g = makeFake({ rule });
    assertEquals(
      (await commentsHandler(g.deps)(req("PATCH", `/comments/${COMMENT_ID}`, { body: "本文" })))
        .status,
      status,
    );
    assertEquals(
      (await commentsHandler(g.deps)(req("DELETE", `/comments/${COMMENT_ID}`))).status,
      status,
    );
  }
});

Deno.test("コメント編集：攻撃的な本文は 422 で更新しない", async () => {
  const f = makeFake();
  const res = await commentsHandler(f.deps)(
    req("PATCH", `/comments/${COMMENT_ID}`, { body: "お前は死ね" }),
  );
  assertEquals(res.status, 422);
  assertEquals(f.calls.updateCommentBody.length, 0);
});

Deno.test("コメント：メソッドが違えば 405、パスが違えば 404", async () => {
  const f = makeFake();
  assertEquals((await commentsHandler(f.deps)(req("GET", "/comments"))).status, 405);
  assertEquals(
    (await commentsHandler(f.deps)(req("PUT", `/comments/${COMMENT_ID}`, {}))).status,
    405,
  );
  assertEquals((await commentsHandler(f.deps)(req("POST", "/other", {}))).status, 404);
});

// --- 共感 ---

Deno.test("共感：登録・選び直し（PUT）と取消（DELETE）。受付状態は確認しない", async () => {
  const f = makeFake();
  const put = await postsHandler(f.deps)(
    req("PUT", `/posts/${POST_ID}/reaction`, { reaction_type_id: 2 }),
  );
  assertEquals(put.status, 200);
  assertEquals(await put.json(), {
    post_id: POST_ID,
    reaction_type_id: 2,
    updated_at: "2026-10-14T00:00:00Z",
  });
  assertEquals(f.calls.setReaction, [{ postId: POST_ID, reactionTypeId: 2 }]);

  const del = await postsHandler(f.deps)(req("DELETE", `/posts/${POST_ID}/reaction`));
  assertEquals(del.status, 200);
  assertEquals(await del.json(), { deleted: true });
  assertEquals(f.calls.removeReaction, [POST_ID]);
});

Deno.test("共感：未ログインは 401。定型文の形式の不備は 422。メソッド違いは 405", async () => {
  const f = makeFake({ loggedIn: false });
  assertEquals(
    (await postsHandler(f.deps)(req("PUT", `/posts/${POST_ID}/reaction`, { reaction_type_id: 1 })))
      .status,
    401,
  );
  const g = makeFake();
  for (
    const body of [{}, { reaction_type_id: "1" }, { reaction_type_id: 0 }, {
      reaction_type_id: 1.5,
    }]
  ) {
    assertEquals(
      (await postsHandler(g.deps)(req("PUT", `/posts/${POST_ID}/reaction`, body))).status,
      422,
    );
  }
  assertEquals(g.calls.setReaction.length, 0);
  assertEquals(
    (await postsHandler(g.deps)(req("PATCH", `/posts/${POST_ID}/reaction`, {}))).status,
    405,
  );
});

Deno.test("共感：ブロック・利用停止・自分の投稿・見えない投稿は、それぞれ 403・404", async () => {
  for (
    const [rule, status] of [["BLOCKED", 403], ["RESTRICTED", 403], ["FORBIDDEN", 403], [
      "NOT_FOUND",
      404,
    ], ["VALIDATION_FAILED", 422]] as const
  ) {
    const f = makeFake({ rule });
    const res = await postsHandler(f.deps)(
      req("PUT", `/posts/${POST_ID}/reaction`, { reaction_type_id: 1 }),
    );
    assertEquals(res.status, status, rule);
  }
});

Deno.test("ブロックされた側への拒否は、レスポンスのどこにもブロックを示す語を含めない（相手に知らせない）", async () => {
  const f = makeFake({ rule: "BLOCKED" });
  for (
    const res of [
      await commentsHandler(f.deps)(req("POST", "/comments", validComment)),
      await postsHandler(f.deps)(req("PUT", `/posts/${POST_ID}/reaction`, { reaction_type_id: 1 })),
    ]
  ) {
    assertEquals(res.status, 403);
    const text = JSON.stringify(await res.json()).toLowerCase();
    assert(!text.includes("block") && !text.includes("ブロック"), text);
  }
});

Deno.test("登録直後の制限：投稿もコメントも 429（RATE_LIMITED）。保存されない", async () => {
  const f = makeFake({ rule: "RATE_LIMITED" });
  const res = await postsHandler(f.deps)(req("POST", "/posts", validPost));
  assertEquals(res.status, 429);
  const e = await errorBody(res);
  assertEquals(e.code, "RATE_LIMITED");
  assertEquals((e.details as { reason: string }).reason, "new_user_limit");

  const c = makeFake({ rule: "RATE_LIMITED" });
  const res2 = await commentsHandler(c.deps)(
    req("POST", "/comments", { post_id: POST_ID, body: "こんにちは" }),
  );
  assertEquals(res2.status, 429);
});

Deno.test("登録直後の制限：DBが返す解除の日時を retry_at に入れる。日時でないものは捨てる", () => {
  const ok = toRuleError({
    code: "P0001",
    message: "RATE_LIMITED",
    details: "2026-10-16 01:32:14.210116+00",
  });
  assert(ok instanceof RuleError);
  assertEquals(ok.code, "RATE_LIMITED");
  assertEquals(ok.retryAt, "2026-10-16T01:32:14.210Z");

  const bad = toRuleError({
    code: "P0001",
    message: "RATE_LIMITED",
    details: "内部の情報 SELECT *",
  });
  assert(bad instanceof RuleError);
  assertEquals(bad.retryAt, undefined);
});
