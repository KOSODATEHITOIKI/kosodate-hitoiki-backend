/**
 * 投稿・コメントの配線（wiring.ts）の結合テスト。ローカルのSupabase（Auth・DB）へ実際に接続する。
 * 送信前チェックの外部API（OpenAI）だけはフェイクにする。
 *
 *   npm run supabase:start && npm run test:functions-integration
 */
import { assert, assertEquals } from "@std/assert";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { ModerationUnavailableError } from "../moderation/types.ts";
import { createProfileDeps } from "../profile/wiring.ts";
import { createProfileHandler } from "../profile/handlers.ts";
import { commentsHandler, postsHandler } from "./handlers.ts";
import type { PostsDeps } from "./types.ts";
import { createPostsDeps } from "./wiring.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

const deps: PostsDeps = {
  ...createPostsDeps(),
  moderation: { moderate: () => Promise.resolve({}) },
};
const profileDeps = {
  ...createProfileDeps(),
  moderation: { moderate: () => Promise.resolve({}) },
  imageModeration: { moderateImage: () => Promise.resolve({}) },
};

function req(method: string, path: string, token: string, body?: unknown, headers = {}) {
  return new Request(`http://localhost${path}`, {
    method,
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}`, ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function signUp(label: string, nickname: string) {
  const email = `${label}-${crypto.randomUUID()}@example.com`;
  const password = "test-password-12345";
  const { data, error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (error) throw new Error("createUser failed");
  const anon = createClient(url, anonKey, { auth: { persistSession: false } });
  const { data: session, error: e2 } = await anon.auth.signInWithPassword({ email, password });
  if (e2 || !session.session) throw new Error("signIn failed");
  const token = session.session.access_token;
  const created = await createProfileHandler(profileDeps)(
    req("POST", "/profile-create", token, { nickname, terms_version: "2026-10" }),
  );
  assertEquals(created.status, 201);
  const client = createClient(url, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  return { userId: data.user.id, token, client };
}

Deno.test("配線：投稿→コメント→返信→編集→削除（実際のAuth・DB）と、公開範囲", async () => {
  const owner = await signUp("owner", "とうこうしゃ");
  const guest = await signUp("guest", "こめんと");
  const anon = createClient(url, anonKey, { auth: { persistSession: false } });
  try {
    // 作成。再送（同じIdempotency-Key）は重複しない
    const first = await postsHandler(deps)(
      req("POST", "/posts", owner.token, {
        post_type: "soudan",
        body: "相談です",
        reaction_mode: "want_comments",
      }, { "Idempotency-Key": "it-key-1" }),
    );
    assertEquals(first.status, 201);
    const postId = (await first.json()).id as string;
    const again = await postsHandler(deps)(
      req("POST", "/posts", owner.token, {
        post_type: "soudan",
        body: "相談です",
        reaction_mode: "want_comments",
      }, { "Idempotency-Key": "it-key-1" }),
    );
    assertEquals((await again.json()).id, postId);
    assertEquals(
      (await admin.from("posts").select("id").eq("author_id", owner.userId)).data?.length,
      1,
    );

    // 公開範囲（未ログイン）：ニックネームは取れるが、利用者IDは取れない
    const pub = await anon.from("public_posts").select("*").eq("id", postId).single();
    assertEquals(pub.data?.author_nickname, "とうこうしゃ");
    assert(!("author_id" in (pub.data ?? {})));
    const direct = await anon.from("posts").select("author_id").limit(1);
    assert(direct.error !== null, "未ログインが posts.author_id を読めてしまった");
    const profiles = await anon.from("public_profiles").select("id").limit(1);
    assert(profiles.error !== null, "未ログインが public_profiles を読めてしまった");

    // コメント・返信
    const c = await commentsHandler(deps)(
      req("POST", "/comments", guest.token, { post_id: postId, body: "わかります" }),
    );
    assertEquals(c.status, 201);
    const commentId = (await c.json()).id as string;
    const r = await commentsHandler(deps)(
      req("POST", "/comments", owner.token, {
        post_id: postId,
        parent_comment_id: commentId,
        body: "ありがとう",
      }),
    );
    assertEquals(r.status, 201);
    const nested = await commentsHandler(deps)(
      req("POST", "/comments", guest.token, {
        post_id: postId,
        parent_comment_id: (await r.json()).id,
        body: "返信への返信",
      }),
    );
    assertEquals(nested.status, 422);

    // コメント一覧（ログイン済み）：ニックネームが付き、未ログインには見えない
    const list = await guest.client.from("member_comments").select("*").eq("post_id", postId)
      .order("created_at", { ascending: true });
    assertEquals(list.data?.length, 2);
    assertEquals(list.data?.[0].author_nickname, "こめんと");
    assertEquals((await anon.from("member_comments").select("id")).error !== null, true);
    assertEquals((await anon.from("comments").select("id")).error !== null, true);

    // 他人は編集・削除できない
    assertEquals(
      (await postsHandler(deps)(
        req("PATCH", `/posts/${postId}`, guest.token, { body: "乗っ取り" }),
      )).status,
      403,
    );
    assertEquals(
      (await postsHandler(deps)(req("DELETE", `/posts/${postId}`, guest.token))).status,
      403,
    );
    assertEquals(
      (await commentsHandler(deps)(req("DELETE", `/comments/${commentId}`, owner.token))).status,
      403,
    );

    // 本人の編集で「編集済み」になる。受付終了後も既存コメントは編集できる
    const edit = await postsHandler(deps)(
      req("PATCH", `/posts/${postId}`, owner.token, { body: "書き直した" }),
    );
    assertEquals(edit.status, 200);
    assert((await edit.json()).edited_at !== null);
    const closed = await postsHandler(deps)(
      req("PATCH", `/posts/${postId}/reaction-mode`, owner.token, {
        reaction_mode: "want_comments",
        comment_acceptance: "closed",
      }),
    );
    assertEquals(closed.status, 200);
    const late = await commentsHandler(deps)(
      req("POST", "/comments", guest.token, { post_id: postId, body: "遅れた" }),
    );
    assertEquals(late.status, 403);
    assertEquals((await late.json()).error.details.reason, "comments_closed");
    assertEquals(
      (await commentsHandler(deps)(
        req("PATCH", `/comments/${commentId}`, guest.token, { body: "書き直しました" }),
      )).status,
      200,
    );

    // 削除：親コメントは本文が消えて返信は残る。投稿を削除するとコメントも消える
    assertEquals(
      (await commentsHandler(deps)(req("DELETE", `/comments/${commentId}`, guest.token))).status,
      200,
    );
    const afterDelete = await guest.client.from("member_comments").select("*").eq("post_id", postId)
      .order("created_at", { ascending: true });
    assertEquals(afterDelete.data?.length, 2);
    assertEquals(afterDelete.data?.[0].is_deleted, true);
    assertEquals(afterDelete.data?.[0].body, null);
    assertEquals(
      (await postsHandler(deps)(req("DELETE", `/posts/${postId}`, owner.token))).status,
      200,
    );
    assertEquals((await admin.from("comments").select("id").eq("post_id", postId)).data?.length, 0);
  } finally {
    await admin.auth.admin.deleteUser(owner.userId);
    await admin.auth.admin.deleteUser(guest.userId);
  }
});

Deno.test("配線：保存済みの再送は、外部API（送信前チェック）が止まっていても返る。相談先の案内も残る（実際のDB）", async () => {
  const caution: PostsDeps = {
    ...createPostsDeps(),
    moderation: { moderate: () => Promise.resolve({ "self-harm": 0.9 }) },
  };
  const down: PostsDeps = {
    ...createPostsDeps(),
    moderation: {
      moderate: () => Promise.reject(new ModerationUnavailableError()),
    },
  };
  const user = await signUp("replay", "さいそう");
  // 登録直後の上限（別の確認）に当たらないよう、登録から日数が経った利用者にする
  await admin.from("profiles").update({
    created_at: new Date(Date.now() - 3 * 24 * 3600 * 1000).toISOString(),
  }).eq("id", user.userId);
  const post = (d: PostsDeps, key: string) =>
    postsHandler(d)(
      req("POST", "/posts", user.token, { post_type: "guchi", body: "つらいです" }, {
        "Idempotency-Key": key,
      }),
    );
  const count = async () =>
    (await admin.from("posts").select("id").eq("author_id", user.userId)).data?.length;
  try {
    const first = await post(caution, "it-replay-key");
    assertEquals(first.status, 201);
    const created = await first.json();
    assertEquals(created.support_notice, true);

    // 応答が届かなかったとして再送。外部APIは止まっているが、保存済みの結果が返る
    const again = await post(down, "it-replay-key");
    assertEquals(again.status, 201);
    const replayed = await again.json();
    assertEquals(replayed.id, created.id);
    assertEquals(replayed.created_at, created.created_at);
    assertEquals(replayed.support_notice, true); // 相談先の案内も、再送で消えない
    assertEquals(await count(), 1);

    // 新しいキーは、保存済みではないので、外部APIの障害（503）になる（保存しない）
    const other = await post(down, "it-replay-other");
    assertEquals(other.status, 503);
    assertEquals(await count(), 1);
  } finally {
    await admin.auth.admin.deleteUser(user.userId);
  }
});
