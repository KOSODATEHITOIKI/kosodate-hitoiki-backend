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
    const blockedBody = JSON.stringify(await blocked.json()).toLowerCase();
    assert(!blockedBody.includes("block"), "拒否の応答がブロックを示している");

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

Deno.test("結合：共感はAPI経由のみ（直接の書き込みは拒否）。件数は投稿者だけ。保存は本人だけ", async () => {
  const owner = await signUp("rx-owner", "とうこうしゃ");
  const fan = await signUp("rx-fan", "きょうかん");
  const anon = createClient(url, anonKey, { auth: { persistSession: false } });
  try {
    await admin.from("reaction_types").insert([{ label: "大変だったね" }, { label: "わかるよ" }]);
    const types = (await admin.from("reaction_types").select("id").order("id")).data!;
    const [t1, t2] = [types[types.length - 2].id as number, types[types.length - 1].id as number];

    const created = await postsHandler(deps)(
      req("POST", "/posts", owner.token, { post_type: "guchi", body: "つらい一日でした" }),
    );
    const postId = (await created.json()).id as string;

    // 共感：登録→選び直し。1投稿1人1つ
    const put = await postsHandler(deps)(
      req("PUT", `/posts/${postId}/reaction`, fan.token, { reaction_type_id: t1 }),
    );
    assertEquals(put.status, 200);
    const again = await postsHandler(deps)(
      req("PUT", `/posts/${postId}/reaction`, fan.token, { reaction_type_id: t2 }),
    );
    assertEquals((await again.json()).reaction_type_id, t2);
    assertEquals((await admin.from("reactions").select("*").eq("post_id", postId)).data?.length, 1);

    // 直接の書き込み（クライアントのREST）は拒否される
    const direct = await fan.client.from("reactions").insert({
      post_id: postId,
      user_id: fan.userId,
      reaction_type_id: t1,
    });
    assert(direct.error !== null, "共感を直接書き込めてしまった");
    assert((await fan.client.from("reactions").delete().eq("post_id", postId)).error !== null);

    // 自分の共感は参照でき、件数は投稿者だけが取得できる。行そのものは投稿者にも見えない
    assertEquals((await fan.client.from("reactions").select("reaction_type_id")).data?.length, 1);
    assertEquals((await fan.client.rpc("get_post_reaction_count", { p_post_id: postId })).data, 0);
    assertEquals(
      (await owner.client.rpc("get_post_reaction_count", { p_post_id: postId })).data,
      1,
    );
    assertEquals((await owner.client.from("reactions").select("*")).data?.length, 0);
    assert((await anon.rpc("get_post_reaction_count", { p_post_id: postId })).error !== null);

    // 取消（冪等）
    const del = await postsHandler(deps)(req("DELETE", `/posts/${postId}/reaction`, fan.token));
    assertEquals((await del.json()).deleted, true);
    const del2 = await postsHandler(deps)(req("DELETE", `/posts/${postId}/reaction`, fan.token));
    assertEquals((await del2.json()).deleted, false);

    // 保存：本人だけ。存在しない投稿IDの保存は、見えない投稿と同じエラー
    assertEquals(
      (await fan.client.from("saved_posts").insert({ user_id: fan.userId, post_id: postId })).error,
      null,
    );
    const missing = await fan.client.from("saved_posts").insert({
      user_id: fan.userId,
      post_id: crypto.randomUUID(),
    });
    assertEquals(missing.error?.code, "42501");
    assertEquals(
      (await fan.client.from("saved_post_list").select("id,saved_at")).data?.map((r) => r.id),
      [postId],
    );
    assertEquals((await owner.client.from("saved_posts").select("*")).data?.length, 0);
    assertEquals((await owner.client.from("saved_post_list").select("id")).data?.length, 0);
    assert((await anon.from("saved_post_list").select("id")).error !== null);
    // 保存・共感では、投稿者へ通知は作られない
    assertEquals((await owner.client.from("notifications").select("id")).data?.length, 0);
  } finally {
    await admin.from("reaction_types").delete().neq("id", 0);
    await admin.auth.admin.deleteUser(owner.userId);
    await admin.auth.admin.deleteUser(fan.userId);
  }
});

Deno.test("結合：検索はREST（RPC）経由で、未ログインでも使え、ブロック・ミュートを適用し、利用者IDを出さない", async () => {
  const owner = await signUp("srch-owner", "とうこうしゃ");
  const viewer = await signUp("srch-viewer", "えつらん");
  const anon = createClient(url, anonKey, { auth: { persistSession: false } });
  try {
    const post = async (body: string) => {
      const r = await postsHandler(deps)(
        req("POST", "/posts", owner.token, { post_type: "guchi", body }),
      );
      assertEquals(r.status, 201);
      return (await r.json()).id as string;
    };
    const id1 = await post("夜泣きがつらい毎晩");
    const id2 = await post("保育園の送迎で悩んでいます");
    await post("ＮＥＴＡバレに注意");

    // 未ログイン：検索できる。1文字・全角半角・複数語（AND）。利用者IDは出ない
    const r1 = await anon.rpc("search_posts", { p_query: "夜泣き" });
    assertEquals(r1.error, null);
    assertEquals((r1.data as { id: string }[]).map((x) => x.id), [id1]);
    assertEquals((r1.data as { author_id: string | null }[])[0].author_id, null);
    assertEquals((r1.data as { author_nickname: string }[])[0].author_nickname, "とうこうしゃ");
    assertEquals(((await anon.rpc("search_posts", { p_query: "夜" })).data as unknown[]).length, 1);
    assertEquals(
      ((await anon.rpc("search_posts", { p_query: "neta" })).data as unknown[]).length,
      1,
    );
    assertEquals(
      ((await anon.rpc("search_posts", { p_query: "送迎 保育園" })).data as unknown[]).length,
      1,
    );
    assertEquals(
      ((await anon.rpc("search_posts", { p_query: "ひみつ" })).data as unknown[]).length,
      0,
    );

    // 入力の検証は 400（PostgRESTの標準形式）。件数は50件までに抑える
    const bad = await anon.rpc("search_posts", { p_query: "夜泣き", p_post_type: "x" });
    assert(bad.error !== null);
    assertEquals(bad.error?.message, "VALIDATION_FAILED");
    const many = await anon.rpc("search_posts", { p_limit: 100000 });
    assert((many.data as unknown[]).length <= 50);

    // ログイン済み：ミュートした言葉・ブロックが検索に反映される。利用者IDを返す
    const before = await viewer.client.rpc("search_posts", { p_query: "夜泣き" });
    assertEquals((before.data as unknown[]).length, 1);
    assertEquals(
      (before.data as { author_id: string }[])[0].author_id,
      owner.userId,
    );
    await viewer.client.from("muted_words").insert({ user_id: viewer.userId, word: "夜泣き" });
    assertEquals(
      ((await viewer.client.rpc("search_posts", { p_query: "夜泣き" })).data as unknown[]).length,
      0,
    );
    // ほかの利用者・未ログインには影響しない
    assertEquals(
      ((await anon.rpc("search_posts", { p_query: "夜泣き" })).data as unknown[]).length,
      1,
    );
    await viewer.client.from("blocks").insert({
      blocker_id: viewer.userId,
      blocked_id: owner.userId,
    });
    assertEquals(
      ((await viewer.client.rpc("search_posts", { p_query: "保育園" })).data as unknown[]).length,
      0,
    );

    // 一時非表示（通報）の投稿は、未ログインにもログイン済みにも出ない
    await admin.from("posts").update({ hidden_at: new Date().toISOString() }).eq("id", id2);
    assertEquals(
      ((await anon.rpc("search_posts", { p_query: "保育園" })).data as unknown[]).length,
      0,
    );
    assertEquals(
      ((await owner.client.rpc("search_posts", { p_query: "保育園" })).data as unknown[]).length,
      0,
    );

    // 関数があっても、元のテーブルを直接読めるようにはなっていない
    assert((await anon.from("muted_words").select("*")).error !== null);
    assert((await anon.from("profiles").select("*")).error !== null);
  } finally {
    await admin.auth.admin.deleteUser(owner.userId);
    await admin.auth.admin.deleteUser(viewer.userId);
  }
});
