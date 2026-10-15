/**
 * 退会の結合テスト。ローカルのSupabase（Auth・DB・Storage）へ実際に接続する。
 * 本物のAuthで、退会後にログインできないこと、データ・画像が消えること、名前が予約されることを確かめる。
 *
 *   npm run supabase:start && npm run test:functions-integration
 */
import { assert, assertEquals } from "@std/assert";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { commentsHandler, postsHandler } from "../posts/handlers.ts";
import { createPostsDeps } from "../posts/wiring.ts";
import { createProfileHandler } from "../profile/handlers.ts";
import { createProfileDeps } from "../profile/wiring.ts";
import { accountDeleteHandler } from "./handlers.ts";
import { createAccountDeps } from "./wiring.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

const accountDeps = createAccountDeps();
const postsDeps = { ...createPostsDeps(), moderation: { moderate: () => Promise.resolve({}) } };
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

const createdUsers: string[] = [];

async function cleanup() {
  await admin.from("admin_users").delete().in("user_id", createdUsers);
  await admin.from("nickname_reservations").delete().in("previous_owner_id", createdUsers);
  await admin.from("notifications").delete().in("actor_id", createdUsers);
  for (const id of createdUsers.splice(0)) await admin.auth.admin.deleteUser(id);
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
  createdUsers.push(data.user.id);
  const { data: s, error: e2 } = await createClient(url, anonKey, {
    auth: { persistSession: false },
  }).auth.signInWithPassword({ email, password });
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
  return { userId: data.user.id, email, password, token, client };
}

Deno.test("結合：退会すると、ログインできず、データと画像が消え、名前が予約される。運営者は退会できない", async () => {
  const leaver = await signUp("wd-leaver", "たいかいしゃ");
  const other = await signUp("wd-other", "のこるひと");
  const staff = await signUp("wd-staff", "うんえいしゃ");
  try {
    // データを作る：投稿・コメント・保存・端末・画像
    const leaverPost = await postsHandler(postsDeps)(
      req("POST", "/posts", leaver.token, {
        post_type: "soudan",
        body: "退会する人の投稿",
        reaction_mode: "want_comments",
      }),
    );
    const leaverPostId = (await leaverPost.json()).id as string;
    const otherPost = await postsHandler(postsDeps)(
      req("POST", "/posts", other.token, {
        post_type: "soudan",
        body: "残る人の投稿",
        reaction_mode: "want_comments",
      }),
    );
    const otherPostId = (await otherPost.json()).id as string;
    assertEquals(
      (await commentsHandler(postsDeps)(
        req("POST", "/comments", other.token, { post_id: leaverPostId, body: "残る人のコメント" }),
      )).status,
      201,
    );
    assertEquals(
      (await commentsHandler(postsDeps)(
        req("POST", "/comments", leaver.token, {
          post_id: otherPostId,
          body: "退会する人のコメント",
        }),
      )).status,
      201,
    );
    await leaver.client.from("saved_posts").insert({
      user_id: leaver.userId,
      post_id: otherPostId,
    });
    await leaver.client.rpc("register_push_device", {
      p_platform: "ios",
      p_token: "withdraw-integration-token-01",
    });
    const png = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
    const uploaded = await admin.storage.from("avatars").upload(`${leaver.userId}/a.png`, png, {
      contentType: "image/png",
    });
    assertEquals(uploaded.error, null);

    // 確認なしは拒否。何も消えない
    assertEquals(
      (await accountDeleteHandler(accountDeps)(req("POST", "/account-delete", leaver.token, {})))
        .status,
      422,
    );
    assertEquals((await admin.from("posts").select("id").eq("id", leaverPostId)).data?.length, 1);

    // 運営者として登録されている人は退会できない。何も消えない
    await admin.from("admin_users").insert({ user_id: staff.userId });
    const staffTry = await accountDeleteHandler(accountDeps)(
      req("POST", "/account-delete", staff.token, { confirm: true }),
    );
    assertEquals(staffTry.status, 409);
    assertEquals((await admin.auth.admin.getUserById(staff.userId)).data.user?.id, staff.userId);

    // 退会
    const res = await accountDeleteHandler(accountDeps)(
      req("POST", "/account-delete", leaver.token, { confirm: true }),
    );
    assertEquals(res.status, 200);
    assertEquals((await res.json()).status, "deleted");

    // Authのアカウントが消え、ログインも古いトークンも使えない
    assert(
      (await admin.auth.admin.getUserById(leaver.userId)).error !== null,
      "アカウントが残った",
    );
    const relogin = await createClient(url, anonKey, { auth: { persistSession: false } })
      .auth.signInWithPassword({ email: leaver.email, password: leaver.password });
    assert(relogin.error !== null, "退会後にログインできてしまった");
    assertEquals(
      (await accountDeleteHandler(accountDeps)(
        req("POST", "/account-delete", leaver.token, { confirm: true }),
      )).status,
      401,
      "退会後の古いトークンが使えた",
    );

    // データと画像が消える。他の人のデータは残る
    assertEquals(
      (await admin.from("profiles").select("id").eq("id", leaver.userId)).data?.length,
      0,
    );
    assertEquals((await admin.from("posts").select("id").eq("id", leaverPostId)).data?.length, 0);
    assertEquals(
      (await admin.from("comments").select("id").eq("post_id", leaverPostId)).data?.length,
      0,
      "自分の投稿についていたコメントが残った",
    );
    assertEquals(
      (await admin.from("comments").select("id").eq("author_id", leaver.userId)).data?.length,
      0,
    );
    assertEquals(
      (await admin.from("saved_posts").select("post_id").eq("user_id", leaver.userId)).data?.length,
      0,
    );
    assertEquals(
      (await admin.from("push_devices").select("id").eq("user_id", leaver.userId)).data?.length,
      0,
    );
    assertEquals(
      (await admin.storage.from("avatars").list(leaver.userId)).data?.length,
      0,
      "画像が残った",
    );
    assertEquals((await admin.from("posts").select("id").eq("id", otherPostId)).data?.length, 1);
    assertEquals(
      (await admin.from("profiles").select("id").eq("id", other.userId)).data?.length,
      1,
    );
    // 公開の閲覧でも、消えた投稿は見えない
    const anon = createClient(url, anonKey, { auth: { persistSession: false } });
    assertEquals(
      (await anon.from("public_posts").select("id").eq("id", leaverPostId)).data?.length,
      0,
    );

    // 名前が30日間予約され、他の人は使えない
    assertEquals(
      (await admin.from("nickname_reservations").select("reason").eq(
        "previous_owner_id",
        leaver.userId,
      ))
        .data?.[0].reason,
      "withdrawn",
    );
    const newcomer = await admin.auth.admin.createUser({
      email: `wd-new-${crypto.randomUUID()}@example.com`,
      password: "test-password-12345",
      email_confirm: true,
    });
    createdUsers.push(newcomer.data.user!.id);
    const s = await createClient(url, anonKey, { auth: { persistSession: false } }).auth
      .signInWithPassword({ email: newcomer.data.user!.email!, password: "test-password-12345" });
    const reuse = await createProfileHandler(profileDeps)(
      req("POST", "/profile-create", s.data.session!.access_token, {
        nickname: "たいかいしゃ",
        terms_version: "2026-10",
      }),
    );
    assert(reuse.status >= 400 && reuse.status < 500, "予約中の名前を他の人が使えた");
  } finally {
    await cleanup();
  }
});
