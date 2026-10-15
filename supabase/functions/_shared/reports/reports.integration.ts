/**
 * 通報・運営の対処の結合テスト。ローカルのSupabase（Auth・DB・REST）へ、利用者・運営者の権限で
 * 実際に接続する。運営者のセッションは、本物のTOTP（認証アプリのコード）で aal1 から aal2 へ上げる。
 *
 *   npm run supabase:start && npm run test:functions-integration
 */
import { assert, assertEquals } from "@std/assert";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { createProfileHandler } from "../profile/handlers.ts";
import { createProfileDeps } from "../profile/wiring.ts";
import { postsHandler } from "../posts/handlers.ts";
import { createPostsDeps } from "../posts/wiring.ts";
import { moderationHandler, reportsHandler } from "./handlers.ts";
import { createReportsDeps } from "./wiring.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

const reportsDeps = createReportsDeps();
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

// --- TOTP（RFC 6238）：認証アプリが作るコードを、テストの中で作る ---
function base32Decode(input: string): Uint8Array {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  const clean = input.replace(/=+$/, "").replace(/\s/g, "").toUpperCase();
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const ch of clean) {
    value = (value << 5) | alphabet.indexOf(ch);
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return new Uint8Array(out);
}

async function totp(secret: string, atMs = Date.now()): Promise<string> {
  const counter = Math.floor(atMs / 1000 / 30);
  const buf = new ArrayBuffer(8);
  new DataView(buf).setBigUint64(0, BigInt(counter));
  const key = await crypto.subtle.importKey(
    "raw",
    base32Decode(secret) as BufferSource,
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const hmac = new Uint8Array(await crypto.subtle.sign("HMAC", key, buf));
  const offset = hmac[hmac.length - 1] & 0x0f;
  const code = ((hmac[offset] & 0x7f) << 24) | (hmac[offset + 1] << 16) |
    (hmac[offset + 2] << 8) | hmac[offset + 3];
  return String(code % 1_000_000).padStart(6, "0");
}

/** このテストで作った利用者。途中で失敗しても、後始末で必ず消す。 */
const createdUsers: string[] = [];

async function cleanup() {
  // 運営の対処の記録は、運営者のアカウント削除を妨げる（外部キー）ため、先に消す。
  await admin.from("moderation_actions").delete().in("admin_id", createdUsers);
  await admin.from("account_restrictions").delete().in("created_by", createdUsers);
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
  const client = createClient(url, anonKey, { auth: { persistSession: false } });
  const { data: s, error: e2 } = await client.auth.signInWithPassword({ email, password });
  if (e2 || !s.session) throw new Error("signIn failed");
  const created = await createProfileHandler(profileDeps)(
    req("POST", "/profile-create", s.session.access_token, { nickname, terms_version: "2026-10" }),
  );
  assertEquals(created.status, 201);
  return { userId: data.user.id, client, email, password, token: s.session.access_token };
}

/** 二段階認証（TOTP）を登録して検証し、aal2 のセッション（アクセストークン）を返す。 */
async function elevateToAal2(user: Awaited<ReturnType<typeof signUp>>): Promise<string> {
  const enroll = await user.client.auth.mfa.enroll({ factorType: "totp" });
  if (enroll.error || !enroll.data || enroll.data.type !== "totp") {
    throw new Error("mfa enroll failed（TOTPが無効？）");
  }
  const challenge = await user.client.auth.mfa.challenge({ factorId: enroll.data.id });
  if (challenge.error || !challenge.data) throw new Error("mfa challenge failed");
  const verify = await user.client.auth.mfa.verify({
    factorId: enroll.data.id,
    challengeId: challenge.data.id,
    code: await totp(enroll.data.totp.secret),
  });
  if (verify.error || !verify.data) throw new Error("mfa verify failed");
  return verify.data.access_token;
}

function jwtAal(token: string): string {
  const part = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
  return JSON.parse(atob(part.padEnd(Math.ceil(part.length / 4) * 4, "="))).aal;
}

Deno.test("結合：通報→自動一時非表示→本人に確認中→運営の対処（二段階認証が必須）", async () => {
  const owner = await signUp("rp-owner", "つうほうされる");
  const r1 = await signUp("rp-r1", "つうほうしゃいち");
  const r2 = await signUp("rp-r2", "つうほうしゃに");
  const r3 = await signUp("rp-r3", "つうほうしゃさん");
  const staff = await signUp("rp-admin", "うんえい");
  const anon = createClient(url, anonKey, { auth: { persistSession: false } });
  try {
    const created = await postsHandler(postsDeps)(
      req("POST", "/posts", owner.token, { post_type: "guchi", body: "通報される投稿" }),
    );
    const postId = (await created.json()).id as string;

    // 通報：重複は件数が増えない。自分の投稿は通報できない。通報は直接書き込めない
    const report = (u: typeof r1, reason = "harassment") =>
      reportsHandler(reportsDeps)(
        req("POST", "/reports", u.token, { target_type: "post", target_id: postId, reason }),
      );
    assertEquals((await report(r1)).status, 201);
    assertEquals((await report(r1, "spam")).status, 200); // 重複
    assertEquals(
      (await admin.from("reports").select("id").eq("target_id", postId)).data?.length,
      1,
    );
    assertEquals(
      (await reportsHandler(reportsDeps)(
        req("POST", "/reports", owner.token, {
          target_type: "post",
          target_id: postId,
          reason: "spam",
        }),
      )).status,
      403,
    );
    assert(
      (await r1.client.from("reports").insert({
        reporter_id: r1.userId,
        target_type: "post",
        target_id: postId,
        reason: "spam",
      })).error !== null,
      "通報を直接書き込めてしまった",
    );

    // 3人目で自動一時非表示。投稿者には「確認中」、ほかの人には見えない
    assertEquals((await report(r2)).status, 201);
    assertEquals(
      ((await anon.from("public_posts").select("id").eq("id", postId)).data ?? []).length,
      1,
    );
    assertEquals((await report(r3)).status, 201);
    assertEquals(
      ((await anon.from("public_posts").select("id").eq("id", postId)).data ?? []).length,
      0,
    );
    // 一時非表示になった投稿への通報は NOT_FOUND（存在を知る手がかりにしない）
    const late = await signUp("rp-late", "おそい");
    assertEquals((await report(late)).status, 404);
    const mine = await owner.client.from("my_posts").select("under_review").eq("id", postId)
      .single();
    assertEquals(mine.data?.under_review, true);

    // 通報者の情報は、通報された側に出ない
    assertEquals((await owner.client.from("reports").select("*")).data?.length, 0);

    // 運営者として登録する（手作業でadmin_usersへ登録する運用を、ここではservice_roleで再現）
    await admin.from("admin_users").insert({ user_id: staff.userId });

    // 二段階認証前（aal1）：一般利用者と同じ扱い。直接のRESTでも、通報の一覧は見えない
    assertEquals(jwtAal(staff.token), "aal1");
    assertEquals((await staff.client.from("admin_report_queue").select("*")).data?.length, 0);
    assertEquals((await staff.client.from("reports").select("*")).data?.length, 0);
    const beforeMfa = await moderationHandler(reportsDeps)(
      req("POST", "/moderation/actions", staff.token, {
        target_type: "post",
        target_id: postId,
        action: "unhide",
      }),
    );
    assertEquals(beforeMfa.status, 403);
    assertEquals((await beforeMfa.json()).error.details.reason, "mfa_required");

    // 運営者ではない利用者には、運営の機能の存在を明かさない
    const notAdmin = await moderationHandler(reportsDeps)(
      req("POST", "/moderation/actions", r1.token, {
        target_type: "post",
        target_id: postId,
        action: "unhide",
      }),
    );
    assertEquals(notAdmin.status, 404);

    // 二段階認証（本物のTOTP）で aal2 に上げる
    const aal2Token = await elevateToAal2(staff);
    assertEquals(jwtAal(aal2Token), "aal2");
    const staffClient = createClient(url, anonKey, {
      auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${aal2Token}` } },
    });

    // 通報一覧が見え、理由・件数・一時非表示が分かる
    const queue = await staffClient.from("admin_report_queue").select("*").eq("target_id", postId)
      .single();
    assertEquals(queue.data?.report_count, 3);
    assertEquals(queue.data?.is_hidden, true);
    assertEquals(queue.data?.target_owner_id, owner.userId);
    assertEquals(queue.data?.body, "通報される投稿");
    assert((await staffClient.from("reports").select("*")).data!.length >= 3);

    // 一般の利用者は、運営の通報一覧を見られない
    assertEquals((await r1.client.from("admin_report_queue").select("*")).data?.length, 0);

    // 再表示：一時非表示が解除され、通報が対応済みになる
    const unhide = await moderationHandler(reportsDeps)(
      req("POST", "/moderation/actions", aal2Token, {
        target_type: "post",
        target_id: postId,
        action: "unhide",
        reason: "誤検知のため再表示",
      }),
    );
    assertEquals(unhide.status, 200);
    assertEquals(
      ((await anon.from("public_posts").select("id").eq("id", postId)).data ?? []).length,
      1,
    );
    assertEquals(
      (await admin.from("reports").select("id").eq("target_id", postId).is("resolved_at", null))
        .data?.length,
      0,
    );

    // 警告・相談先の案内・利用停止：本人へ通知される。利用停止は再ログインを求める
    const warn = await moderationHandler(reportsDeps)(
      req("POST", "/moderation/actions", aal2Token, {
        target_type: "user",
        target_id: owner.userId,
        action: "warn",
        reason: "攻撃的な表現が続いています",
      }),
    );
    assertEquals(warn.status, 200);
    const noReason = await moderationHandler(reportsDeps)(
      req("POST", "/moderation/actions", aal2Token, {
        target_type: "user",
        target_id: owner.userId,
        action: "suspend",
      }),
    );
    assertEquals(noReason.status, 422); // 利用停止には理由が必要
    const suspend = await moderationHandler(reportsDeps)(
      req("POST", "/moderation/actions", aal2Token, {
        target_type: "user",
        target_id: owner.userId,
        action: "suspend",
        reason: "悪質なため",
      }),
    );
    const suspendBody = await suspend.json();
    assertEquals(suspend.status, 200, JSON.stringify(suspendBody));
    assertEquals(suspendBody.restriction_stage, 1);
    const again = await moderationHandler(reportsDeps)(
      req("POST", "/moderation/actions", aal2Token, {
        target_type: "user",
        target_id: owner.userId,
        action: "suspend",
        reason: "二重",
      }),
    );
    assertEquals(again.status, 409);

    // 停止された本人：セッションが取り消される（再ログインが必要）
    const refreshed = await owner.client.auth.refreshSession();
    assert(
      refreshed.error !== null || refreshed.data.session === null,
      "停止後もセッションが生きている",
    );
    const relogin = createClient(url, anonKey, { auth: { persistSession: false } });
    const signedIn = await relogin.auth.signInWithPassword({
      email: owner.email,
      password: owner.password,
    });
    assertEquals(signedIn.error, null);
    const ownerNew = signedIn.data.session!.access_token;
    // 再ログインはできるが、書き込みは利用停止で拒否される。自分の制限の状態は参照できる
    const blockedPost = await postsHandler(postsDeps)(
      req("POST", "/posts", ownerNew, { post_type: "guchi", body: "停止中の投稿" }),
    );
    assertEquals(blockedPost.status, 403);
    assertEquals((await blockedPost.json()).error.details.reason, "restricted");
    const ownerClient = createClient(url, anonKey, {
      auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${ownerNew}` } },
    });
    assertEquals(
      (await ownerClient.from("account_restrictions").select("stage").eq("user_id", owner.userId))
        .data?.[0].stage,
      1,
    );
    // 本人は、自分への対処（警告・利用停止）の理由を読める。通報者の情報は含まれない
    const notices = await ownerClient.from("notifications").select("moderation_action_id")
      .eq("notification_type", "moderation");
    assertEquals(notices.data?.length, 2);
    const reasons = await ownerClient.from("moderation_actions").select("reason,action");
    assertEquals(
      (reasons.data ?? []).map((r) => r.action).sort(),
      ["suspend", "unhide", "warn"],
    );
    assertEquals((await ownerClient.from("reports").select("*")).data?.length, 0);
  } finally {
    await cleanup();
  }
});
