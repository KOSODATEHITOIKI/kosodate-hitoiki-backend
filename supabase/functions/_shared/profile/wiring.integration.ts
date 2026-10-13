/**
 * 配線（wiring.ts）の結合テスト。ローカルのSupabase（Auth・DB・Storage）へ実際に接続する。
 * 送信前チェックの外部API（OpenAI）だけはフェイクにする（キー・課金が不要で、結果を固定するため）。
 *
 *   npm run supabase:start && npm run test:functions-integration
 *
 * 通常の `deno test`（*_test.ts）には含めない。環境変数は supabase/tests/functions/run.sh が設定する。
 */
import { assert, assertEquals } from "@std/assert";
import { createClient } from "@supabase/supabase-js";
import {
  avatarHandler,
  changeNicknameHandler,
  createProfileHandler,
  updateProfileHandler,
} from "./handlers.ts";
import type { ProfileDeps } from "./types.ts";
import { createProfileDeps } from "./wiring.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
const anon = createClient(url, anonKey, { auth: { persistSession: false } });

// 実配線をそのまま使い、外部の送信前チェックだけ「問題なし」に差し替える。
const deps: ProfileDeps = {
  ...createProfileDeps(),
  moderation: { moderate: () => Promise.resolve({}) },
  imageModeration: { moderateImage: () => Promise.resolve({}) },
};

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4]);

function req(method: string, token: string, body?: unknown, contentType = "application/json") {
  return new Request("http://localhost/fn", {
    method,
    headers: { "Content-Type": contentType, Authorization: `Bearer ${token}` },
    body: body === undefined
      ? undefined
      : body instanceof Uint8Array
      ? body as BodyInit
      : JSON.stringify(body),
  });
}

async function signUp(label: string) {
  const email = `${label}-${crypto.randomUUID()}@example.com`;
  const password = "test-password-12345";
  const { data, error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (error) throw new Error("createUser failed");
  const { data: session, error: e2 } = await anon.auth.signInWithPassword({ email, password });
  if (e2 || !session.session) throw new Error("signIn failed");
  return { userId: data.user.id, token: session.session.access_token };
}

Deno.test("配線：登録→ニックネーム変更→更新→画像→削除（実際のAuth・DB・Storage）", async () => {
  const { userId, token } = await signUp("profile");
  try {
    // 未ログイン・不正なトークンは 401
    assertEquals(
      (await createProfileHandler(deps)(req("POST", "invalid-token", { nickname: "はなこ" })))
        .status,
      401,
    );

    // 登録：プロフィール・利用規約同意・通知設定が作られる
    const created = await createProfileHandler(deps)(req("POST", token, {
      nickname: "はなこ",
      bio: "よろしくね",
      child_age_range: "0〜1歳",
      terms_version: "2026-10",
    }));
    assertEquals(created.status, 201);
    const profile = await admin.from("profiles").select("*").eq("id", userId).single();
    assertEquals(profile.data?.nickname, "はなこ");
    assertEquals(profile.data?.normalized_nickname, "はなこ");
    const terms = await admin.from("terms_acceptances").select("terms_version").eq(
      "user_id",
      userId,
    );
    assertEquals(terms.data, [{ terms_version: "2026-10" }]);
    const settings = await admin.from("notification_settings").select("user_id").eq(
      "user_id",
      userId,
    );
    assertEquals(settings.data?.length, 1);

    // 再送（同じ内容）は重複せず 200
    const retry = await createProfileHandler(deps)(req("POST", token, {
      nickname: "はなこ",
      terms_version: "2026-10",
    }));
    assertEquals(retry.status, 200);

    // 初回のニックネーム変更は許可、続けての変更は30日制限で 422
    const changed = await changeNicknameHandler(deps)(
      req("POST", token, { nickname: "あたらしい" }),
    );
    assertEquals(changed.status, 200);
    const again = await changeNicknameHandler(deps)(req("POST", token, { nickname: "またかえる" }));
    assertEquals(again.status, 422);
    // 旧名は本人のために予約されている
    const reservation = await admin.from("nickname_reservations").select("previous_owner_id")
      .eq("normalized_nickname", "はなこ").single();
    assertEquals(reservation.data?.previous_owner_id, userId);

    // 更新：自己紹介
    const updated = await updateProfileHandler(deps)(req("PATCH", token, { bio: "更新しました" }));
    assertEquals(updated.status, 200);
    assertEquals(
      (await admin.from("profiles").select("bio").eq("id", userId).single()).data?.bio,
      "更新しました",
    );

    // 画像アップロード：保存され、public_profiles に公開される
    const up1 = await avatarHandler(deps)(req("PUT", token, PNG, "image/png"));
    assertEquals(up1.status, 200);
    const path1 = (await up1.json()).avatar_path as string;
    assert(path1.startsWith(`${userId}/`));
    assertEquals((await admin.storage.from("avatars").download(path1)).error, null);
    const pub = await anon.from("public_profiles").select("avatar_path").eq("id", userId).single();
    assertEquals(pub.data?.avatar_path, path1);

    // 画像の差し替え：旧画像が削除される
    const up2 = await avatarHandler(deps)(req("PUT", token, PNG, "image/png"));
    const path2 = (await up2.json()).avatar_path as string;
    assert(path1 !== path2);
    assert((await admin.storage.from("avatars").download(path1)).error !== null);
    assertEquals((await admin.storage.from("avatars").download(path2)).error, null);

    // イラストを選ぶと、アップロード画像が外れてファイルも消える
    const icon = await updateProfileHandler(deps)(req("PATCH", token, { icon_key: "bear_01" }));
    assertEquals(icon.status, 200);
    const after = await admin.from("profiles").select("icon_key, avatar_path").eq("id", userId)
      .single();
    assertEquals(after.data, { icon_key: "bear_01", avatar_path: null });
    assert((await admin.storage.from("avatars").download(path2)).error !== null);

    // クライアント（利用者の権限）からは、avatars へ直接アップロードできない
    const userClient = createClient(url, anonKey, {
      auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const direct = await userClient.storage.from("avatars").upload(
      `${userId}/direct.png`,
      PNG,
      { contentType: "image/png" },
    );
    assert(direct.error !== null, "クライアントから直接アップロードできてしまった");

    // クライアントから profiles へ直接書き込めない（送信前チェックの迂回）
    const directWrite = await userClient.from("profiles").update({ bio: "直接" }).eq("id", userId)
      .select("id");
    assert(directWrite.error !== null || (directWrite.data ?? []).length === 0);
    assertEquals(
      (await admin.from("profiles").select("bio").eq("id", userId).single()).data?.bio,
      "更新しました",
    );
  } finally {
    await admin.auth.admin.deleteUser(userId);
  }
});

Deno.test("配線：同じ名前を他の人が使っていると登録できない（一意制約 → 409）", async () => {
  const a = await signUp("dup-a");
  const b = await signUp("dup-b");
  try {
    const first = await createProfileHandler(deps)(req("POST", a.token, {
      nickname: "Same",
      terms_version: "2026-10",
    }));
    assertEquals(first.status, 201);
    // 全角・大文字小文字の違いは同一視される
    const second = await createProfileHandler(deps)(req("POST", b.token, {
      nickname: "ｓａｍｅ",
      terms_version: "2026-10",
    }));
    assertEquals(second.status, 409);
    // 失敗した登録は、規約同意などを残さない
    assertEquals(
      (await admin.from("terms_acceptances").select("user_id").eq("user_id", b.userId)).data
        ?.length,
      0,
    );
  } finally {
    await admin.auth.admin.deleteUser(a.userId);
    await admin.auth.admin.deleteUser(b.userId);
  }
});
