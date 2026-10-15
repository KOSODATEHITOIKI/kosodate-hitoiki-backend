/**
 * 通知・端末の登録の結合テスト。ローカルのSupabase（Auth・DB・REST）へ、利用者の権限で実際に接続する。
 * 「本人だけが読める・既読にできる」「端末の直接登録ができない」「別の人が端末を使い始めたら持ち主が移る」を、
 * 本物のAuth・RLS・権限で確かめる。
 *
 *   npm run supabase:start && npm run test:functions-integration
 */
import { assert, assertEquals } from "@std/assert";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { commentsHandler, postsHandler } from "../posts/handlers.ts";
import { createPostsDeps } from "../posts/wiring.ts";
import { createProfileHandler } from "../profile/handlers.ts";
import { createProfileDeps } from "../profile/wiring.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

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
  // 通知の発生元（actor_id）は外部キーで残るため、先に消す。
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
  return { userId: data.user.id, token, client };
}

Deno.test("結合：通知は本人だけが読み・既読にできる。端末は関数だけで登録でき、持ち主が移る", async () => {
  const owner = await signUp("nt-owner", "とうこうぬし");
  const commenter = await signUp("nt-commenter", "こめんとする");
  const other = await signUp("nt-other", "かんけいない");
  const anon = createClient(url, anonKey, { auth: { persistSession: false } });
  try {
    const created = await postsHandler(postsDeps)(
      req("POST", "/posts", owner.token, {
        post_type: "soudan",
        body: "相談です",
        reaction_mode: "want_comments",
      }),
    );
    assertEquals(created.status, 201);
    const postId = (await created.json()).id as string;

    // 端末を登録してから、コメントを受ける
    assertEquals(
      (await owner.client.rpc("register_push_device", {
        p_platform: "ios",
        p_token: "integration-device-token-0001",
      })).error,
      null,
    );
    const commented = await commentsHandler(postsDeps)(
      req("POST", "/comments", commenter.token, { post_id: postId, body: "コメントです" }),
    );
    assertEquals(commented.status, 201);

    // 通知：投稿者だけが読める。コメントした人・無関係の人・未ログインには見えない
    const mine = await owner.client.from("notifications").select("*");
    assertEquals(mine.data?.length, 1);
    assertEquals(mine.data?.[0].notification_type, "comment");
    assertEquals((await commenter.client.from("notifications").select("*")).data?.length, 0);
    assertEquals((await other.client.from("notifications").select("*")).data?.length, 0);
    assert((await anon.from("notifications").select("*")).error !== null, "未ログインが読めた");

    // 既読：本人だけ。ほかの列・他人の通知は変えられない
    const id = mine.data![0].id as string;
    await other.client.from("notifications").update({ is_read: true }).eq("id", id);
    await commenter.client.from("notifications").update({ is_read: true }).eq("id", id);
    assertEquals(
      (await admin.from("notifications").select("is_read").eq("id", id).single()).data?.is_read,
      false,
      "他人が既読にできた",
    );
    const tamper = await owner.client.from("notifications").update({ user_id: other.userId })
      .eq("id", id);
    assert(tamper.error !== null, "通知の宛先を書き換えられた");
    assertEquals(
      (await owner.client.from("notifications").update({ is_read: true }).eq("id", id)).error,
      null,
    );
    assertEquals(
      (await admin.from("notifications").select("is_read").eq("id", id).single()).data?.is_read,
      true,
    );

    // 配信キューは、利用者から見えない・触れない。配信の取り出しも呼べない
    for (const c of [owner.client, anon]) {
      assert((await c.from("push_deliveries").select("*")).error !== null, "配信キューが読めた");
      assert((await c.rpc("claim_push_deliveries", { p_limit: 10 })).error !== null);
      assert(
        (await c.rpc("finish_push_delivery", {
          p_delivery_id: crypto.randomUUID(),
          p_outcome: "sent",
        }))
          .error !== null,
      );
    }
    assert(
      (await anon.rpc("generate_reaction_digests")).error !== null,
      "まとめ通知を誰でも生成できた",
    );
    assert(
      (await owner.client.rpc("generate_reaction_digests")).error !== null,
      "利用者がまとめ通知を生成できた",
    );

    // 端末：直接の登録はできない。未ログインは関数も使えない
    const direct = await owner.client.from("push_devices").insert({
      user_id: owner.userId,
      platform: "ios",
      device_token: "direct-insert-token-0002",
    });
    assert(direct.error !== null, "端末を直接登録できた");
    assert(
      (await anon.rpc("register_push_device", {
        p_platform: "ios",
        p_token: "anon-token-00000001",
      }))
        .error !== null,
    );
    // 配信が積まれている（端末の登録後にできた通知）
    assertEquals(
      (await admin.from("push_deliveries").select("id").eq("notification_id", id)).data?.length,
      1,
    );

    // 別の人が同じ端末を使い始める：持ち主が移り、前の人宛ての配信は消える
    assertEquals(
      (await other.client.rpc("register_push_device", {
        p_platform: "ios",
        p_token: "integration-device-token-0001",
      })).error,
      null,
    );
    assertEquals((await owner.client.from("push_devices").select("id")).data?.length, 0);
    assertEquals((await other.client.from("push_devices").select("id")).data?.length, 1);
    assertEquals(
      (await admin.from("push_deliveries").select("id").eq("notification_id", id)).data?.length,
      0,
      "前の持ち主宛ての配信が残った",
    );

    // 本人は、自分の端末を解除できる（ログアウト時）。他人の端末は消せない
    await owner.client.from("push_devices").delete().eq(
      "device_token",
      "integration-device-token-0001",
    );
    assertEquals((await other.client.from("push_devices").select("id")).data?.length, 1);
    await other.client.from("push_devices").delete().eq(
      "device_token",
      "integration-device-token-0001",
    );
    assertEquals((await other.client.from("push_devices").select("id")).data?.length, 0);

    // 設定：本人だけが変えられる。止めた種類は、通知が作られない
    assertEquals(
      (await owner.client.from("notification_settings").update({ comments_enabled: false })
        .eq("user_id", owner.userId)).error,
      null,
    );
    await other.client.from("notification_settings").update({ comments_enabled: true })
      .eq("user_id", owner.userId);
    assertEquals(
      (await admin.from("notification_settings").select("comments_enabled").eq(
        "user_id",
        owner.userId,
      )
        .single()).data?.comments_enabled,
      false,
    );
    const second = await commentsHandler(postsDeps)(
      req("POST", "/comments", commenter.token, { post_id: postId, body: "2つ目のコメント" }),
    );
    assertEquals(second.status, 201);
    assertEquals((await owner.client.from("notifications").select("*")).data?.length, 1);
  } finally {
    await cleanup();
  }
});
