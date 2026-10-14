/**
 * ブロック・非表示・ミュートの結合テスト。ローカルのSupabase（Auth・DB・REST）へ、利用者の権限で
 * 実際にPostgREST経由で接続する（SQLの直接実行ではなく、クライアントが使う経路そのもの）。
 *
 *   npm run supabase:start && npm run test:functions-integration
 */
import { assert, assertEquals } from "@std/assert";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { createProfileHandler } from "../profile/handlers.ts";
import { createProfileDeps } from "../profile/wiring.ts";
import { commentsHandler, postsHandler } from "./handlers.ts";
import { createPostsDeps } from "./wiring.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

const deps = { ...createPostsDeps(), moderation: { moderate: () => Promise.resolve({}) } };
const profileDeps = {
  ...createProfileDeps(),
  moderation: { moderate: () => Promise.resolve({}) },
  imageModeration: { moderateImage: () => Promise.resolve({}) },
};

function req(method: string, path: string, token: string, body?: unknown) {
  return new Request(`http://localhost${path}`, {
    method,
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
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
  const { data: s, error: e2 } = await createClient(url, anonKey, {
    auth: { persistSession: false },
  })
    .auth.signInWithPassword({ email, password });
  if (e2 || !s.session) throw new Error("signIn failed");
  const token = s.session.access_token;
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

Deno.test("結合：ブロックは一覧・詳細・コメントに反映され、相手のコメント・返信は拒否され、相手に通知しない", async () => {
  const a = await signUp("blk-a", "えーさん");
  const b = await signUp("blk-b", "びーさん");
  try {
    const postOf = async (u: typeof a, body: string, mode = "quiet_support") => {
      const r = await postsHandler(deps)(
        req("POST", "/posts", u.token, { post_type: "soudan", body, reaction_mode: mode }),
      );
      assertEquals(r.status, 201);
      return (await r.json()).id as string;
    };
    const aPost = await postOf(a, "Aの相談", "want_comments");
    const bPost = await postOf(b, "Bの投稿");

    // Bが、Aの投稿にコメントする（ブロック前）
    const c = await commentsHandler(deps)(
      req("POST", "/comments", b.token, { post_id: aPost, body: "Bのコメント" }),
    );
    assertEquals(c.status, 201);

    // ブロック前：Aから、Bの投稿・コメントが見える
    assertEquals((await a.client.from("feed_posts").select("id").eq("id", bPost)).data?.length, 1);
    assertEquals(
      (await a.client.from("member_comments").select("id").eq("post_id", aPost)).data?.length,
      1,
    );

    // AがBをブロック（クライアントがREST経由で直接行う）。重複は一意制約で拒否される
    const block = await a.client.from("blocks").insert({
      blocker_id: a.userId,
      blocked_id: b.userId,
    });
    assertEquals(block.error, null);
    const dup = await a.client.from("blocks").insert({
      blocker_id: a.userId,
      blocked_id: b.userId,
    });
    assertEquals(dup.error?.code, "23505");

    // ブロック後：Aには、Bの投稿・コメント・通知が出ない
    assertEquals((await a.client.from("feed_posts").select("id").eq("id", bPost)).data?.length, 0);
    assertEquals(
      (await a.client.from("member_posts").select("id").eq("id", bPost)).data?.length,
      0,
    );
    assertEquals(
      (await a.client.from("member_comments").select("id").eq("post_id", aPost)).data?.length,
      0,
    );
    assertEquals((await a.client.from("notifications").select("id")).data?.length, 0);

    // Bは、ブロックされている事実を参照できず、Aの公開投稿は見える（公開のため）
    assertEquals((await b.client.from("blocks").select("*")).data?.length, 0);
    assertEquals((await b.client.from("feed_posts").select("id").eq("id", aPost)).data?.length, 1);
    assertEquals((await b.client.from("notifications").select("id")).data?.length, 0);

    // Bからのコメント・返信は、サーバーが拒否する（直接のAPI呼び出し）
    const blocked = await commentsHandler(deps)(
      req("POST", "/comments", b.token, { post_id: aPost, body: "ブロックされたあとのコメント" }),
    );
    assertEquals(blocked.status, 403);
    assertEquals((await blocked.json()).error.details.reason, "blocked");

    // 解除すると、また見える。解除の重複はエラーにならない
    assertEquals((await a.client.from("blocks").delete().eq("blocked_id", b.userId)).error, null);
    assertEquals((await a.client.from("blocks").delete().eq("blocked_id", b.userId)).error, null);
    assertEquals((await a.client.from("feed_posts").select("id").eq("id", bPost)).data?.length, 1);
  } finally {
    await admin.auth.admin.deleteUser(a.userId);
    await admin.auth.admin.deleteUser(b.userId);
  }
});

Deno.test("結合：ミュートは一覧に効き、詳細には効かない。言葉は上限を超えられない", async () => {
  const a = await signUp("mut-a", "みゅーと");
  const b = await signUp("mut-b", "とうこう");
  try {
    const r = await postsHandler(deps)(
      req("POST", "/posts", b.token, {
        post_type: "guchi",
        body: "夜泣きがＮＥＴＡバレみたいにつらい",
      }),
    );
    const postId = (await r.json()).id as string;

    assertEquals((await a.client.from("feed_posts").select("id").eq("id", postId)).data?.length, 1);
    const mute = await a.client.from("muted_words").insert({
      user_id: a.userId,
      word: " ネタバレ ",
    });
    assertEquals(mute.error, null);
    // 全角・半角は区別しないが、「ネタ」と「ＮＥＴＡ」は別の言葉なので、この投稿は出たまま
    assertEquals((await a.client.from("feed_posts").select("id").eq("id", postId)).data?.length, 1);
    assertEquals(
      (await a.client.from("muted_words").insert({ user_id: a.userId, word: "夜泣き" })).error,
      null,
    );
    assertEquals((await a.client.from("feed_posts").select("id").eq("id", postId)).data?.length, 0);
    assertEquals(
      (await a.client.from("member_posts").select("id").eq("id", postId)).data?.length,
      1,
    );

    // 他の利用者のミュート設定は参照できず、影響もしない
    assertEquals((await b.client.from("muted_words").select("*")).data?.length, 0);
    assertEquals((await b.client.from("feed_posts").select("id").eq("id", postId)).data?.length, 1);

    // 上限（暫定100件）
    const rows = Array.from({ length: 98 }, (_, i) => ({ user_id: a.userId, word: `w-${i}` }));
    assertEquals((await a.client.from("muted_words").insert(rows)).error, null);
    const over = await a.client.from("muted_words").insert({ user_id: a.userId, word: "あふれる" });
    assert(over.error !== null, "上限を超えて登録できてしまった");
    assertEquals(over.error?.code, "54000");
  } finally {
    await admin.auth.admin.deleteUser(a.userId);
    await admin.auth.admin.deleteUser(b.userId);
  }
});
