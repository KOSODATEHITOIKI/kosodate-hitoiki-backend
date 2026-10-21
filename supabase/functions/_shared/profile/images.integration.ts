/**
 * 画像まわりと、外部API前の確認の結合テスト。ローカルのSupabase（Auth・DB・Storage）へ実際に接続する。
 * 公開バケットに保存された画像から位置情報が除かれていること、削除待ちが成功するまで残ること、
 * 登録直後の上限・リクエスト上限に達した人が、外部API（送信前チェック）を呼べないことを確かめる。
 *
 *   npm run supabase:start && npm run test:functions-integration
 */
import { assert, assertEquals } from "@std/assert";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { postsHandler } from "../posts/handlers.ts";
import { createPostsDeps } from "../posts/wiring.ts";
import {
  avatarHandler,
  createProfileHandler,
  drainPendingDeletions,
  updateProfileHandler,
} from "./handlers.ts";
import { JPEG, JPEG_WITH_GPS, PNG } from "./test_helpers.ts";
import { createProfileDeps } from "./wiring.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

/** 送信前チェック（外部API）の呼び出しを数える。 */
const calls = { text: 0, image: 0 };
const profileDeps = {
  ...createProfileDeps(),
  moderation: {
    moderate: () => {
      calls.text++;
      return Promise.resolve({});
    },
  },
  imageModeration: {
    moderateImage: () => {
      calls.image++;
      return Promise.resolve({});
    },
  },
};
const postsDeps = {
  ...createPostsDeps(),
  moderation: {
    moderate: () => {
      calls.text++;
      return Promise.resolve({});
    },
  },
};

function req(method: string, path: string, token: string, body?: unknown) {
  return new Request(`http://localhost${path}`, {
    method,
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

function imageReq(token: string, bytes: Uint8Array, type: string) {
  return new Request("http://localhost/profile-avatar", {
    method: "PUT",
    headers: { "Content-Type": type, Authorization: `Bearer ${token}` },
    body: bytes as BodyInit,
  });
}

const createdUsers: string[] = [];

async function cleanup() {
  for (const id of createdUsers.splice(0)) {
    // Authの削除APIが成功すること自体も確かめる（画像のあるユーザーの削除が失敗しない）
    const { error } = await admin.auth.admin.deleteUser(id);
    assertEquals(error, null, "Authのユーザー削除に失敗した");
  }
  await admin.from("pending_storage_deletions").delete().like("path", "%integration-image-test%");
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
  return { userId: data.user.id, token };
}

const text = (bytes: Uint8Array) => new TextDecoder("latin1").decode(bytes);

Deno.test("結合：公開バケットの画像から位置情報が除かれ、差し替えた旧画像は削除される。失敗した削除は待ちに残って再試行される", async () => {
  const user = await signUp("img", "がぞうのひと");
  const avatars = admin.storage.from("avatars");
  try {
    // GPSつきの画像をアップロード → 保存された画像（公開URLから誰でも取れるもの）に位置情報がない
    assert(text(JPEG_WITH_GPS).includes("GPSLatitude"), "テストの画像にGPSが入っていない");
    const res = await avatarHandler(profileDeps)(imageReq(user.token, JPEG_WITH_GPS, "image/jpeg"));
    assertEquals(res.status, 200);
    const firstPath = (await res.json()).avatar_path as string;
    const stored = await avatars.download(firstPath);
    assertEquals(stored.error, null);
    const storedBytes = new Uint8Array(await stored.data!.arrayBuffer());
    assert(!text(storedBytes).includes("GPS"), "公開された画像に位置情報が残っている");
    assert(!text(storedBytes).includes("Exif"));
    assertEquals(storedBytes.length < JPEG_WITH_GPS.length, true);

    // 公開URL（認証なし）からも同じ内容が取れる
    const publicUrl = avatars.getPublicUrl(firstPath).data.publicUrl;
    const fetched = new Uint8Array(await (await fetch(publicUrl)).arrayBuffer());
    assert(!text(fetched).includes("GPS"));

    // 画像を差し替える → 旧画像は削除され、削除待ちも空になる
    const second = await avatarHandler(profileDeps)(imageReq(user.token, PNG, "image/png"));
    assertEquals(second.status, 200);
    assert((await avatars.download(firstPath)).error !== null, "旧画像が残った");
    assertEquals(
      (await admin.from("pending_storage_deletions").select("path").eq("path", firstPath)).data
        ?.length,
      0,
    );

    // 削除に失敗した分は削除待ちに残り、あとの再試行で削除される
    const orphan = `${user.userId}/integration-image-test.png`;
    assertEquals((await avatars.upload(orphan, PNG, { contentType: "image/png" })).error, null);
    await admin.from("pending_storage_deletions").insert({ bucket: "avatars", path: orphan });
    assertEquals(await drainPendingDeletions(profileDeps), 1);
    assert((await avatars.download(orphan)).error !== null, "削除待ちの画像が残った");
    assertEquals(
      (await admin.from("pending_storage_deletions").select("path").eq("path", orphan)).data
        ?.length,
      0,
    );

    // イラストへ変更 → アップロード画像が外れ、そのファイルも削除される
    const current = (await admin.from("profiles").select("avatar_path").eq("id", user.userId)
      .single()).data!.avatar_path as string;
    const upd = await updateProfileHandler(profileDeps)(
      req("PATCH", "/profile-update", user.token, { icon_key: "sun" }),
    );
    assertEquals(upd.status, 200);
    assert((await avatars.download(current)).error !== null, "イラストへ変更後も画像が残った");
  } finally {
    await cleanup();
  }
});

Deno.test("結合：構造が壊れた画像・画像データのない画像は、確認も保存もせずに拒否する", async () => {
  const user = await signUp("img-bad", "こわれたがぞう");
  try {
    const before = calls.image;
    const res = await avatarHandler(profileDeps)(
      imageReq(user.token, new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]), "image/jpeg"),
    );
    assertEquals(res.status, 422);
    assertEquals(calls.image, before, "壊れた画像で外部APIを呼んだ");
    assertEquals(
      (await admin.storage.from("avatars").list(user.userId)).data?.length,
      0,
    );
  } finally {
    await cleanup();
  }
});

Deno.test("結合：画像の上限（10分に10回）に達したら、外部APIを呼ばずに 429", async () => {
  const user = await signUp("img-limit", "れんだするひと");
  try {
    const before = calls.image;
    for (let i = 0; i < 10; i++) {
      assertEquals(
        (await avatarHandler(profileDeps)(imageReq(user.token, JPEG, "image/jpeg"))).status,
        200,
        `${i + 1}回目`,
      );
    }
    assertEquals(calls.image - before, 10);
    const over = await avatarHandler(profileDeps)(imageReq(user.token, JPEG, "image/jpeg"));
    assertEquals(over.status, 429);
    const e = (await over.json()).error;
    assertEquals(e.code, "RATE_LIMITED");
    assertEquals(e.details.reason, "request_limit");
    assertEquals(calls.image - before, 10, "上限を超えた要求で外部APIを呼んだ");
  } finally {
    await cleanup();
  }
});

Deno.test("結合：登録直後の投稿の上限に達した人は、外部APIを呼べない（送信前チェックの前に止まる）", async () => {
  const user = await signUp("post-limit", "とうこうしすぎ");
  try {
    const post = (body: string) =>
      postsHandler(postsDeps)(req("POST", "/posts", user.token, { post_type: "guchi", body }));
    const before = calls.text;
    assertEquals((await post("1件目")).status, 201);
    assertEquals(calls.text - before, 1);

    const second = await post("2件目");
    assertEquals(second.status, 429);
    assertEquals((await second.json()).error.details.reason, "new_user_limit");
    assertEquals(calls.text - before, 1, "上限に達した要求で外部APIを呼んだ");
    // 何度繰り返しても、外部APIは呼ばれない
    for (let i = 0; i < 5; i++) await post(`連打${i}`);
    assertEquals(calls.text - before, 1);
  } finally {
    await cleanup();
  }
});

Deno.test("結合：利用停止中の人は、外部APIを呼べない", async () => {
  const user = await signUp("restricted", "ていしちゅう");
  try {
    await admin.from("account_restrictions").insert({
      user_id: user.userId,
      stage: 1,
      ends_at: new Date(Date.now() + 7 * 24 * 3600 * 1000).toISOString(),
    });
    const before = calls.text;
    const res = await postsHandler(postsDeps)(
      req("POST", "/posts", user.token, { post_type: "guchi", body: "停止中の投稿" }),
    );
    assertEquals(res.status, 403);
    assertEquals(calls.text, before, "利用停止中の要求で外部APIを呼んだ");
  } finally {
    await cleanup();
  }
});

Deno.test("結合：Authの削除APIで、画像のあるユーザーを削除できる。画像は削除待ちに記録され、あとで消える", async () => {
  const user = await signUp("img-del", "さくじょするひと");
  const avatars = admin.storage.from("avatars");
  try {
    const res = await avatarHandler(profileDeps)(imageReq(user.token, PNG, "image/png"));
    assertEquals(res.status, 200);
    const path = (await res.json()).avatar_path as string;
    // Auth（GoTrue）の権限でユーザーを削除する。プロフィールのカスケード削除で、削除待ちへの記録が動く
    const deleted = await admin.auth.admin.deleteUser(user.userId);
    assertEquals(deleted.error, null);
    createdUsers.splice(createdUsers.indexOf(user.userId), 1);
    assertEquals(
      (await admin.from("pending_storage_deletions").select("path").eq("path", path)).data?.length,
      1,
      "削除待ちに記録されなかった",
    );
    assertEquals(await drainPendingDeletions(profileDeps), 1);
    assert((await avatars.download(path)).error !== null, "ユーザー削除後も画像が残った");
  } finally {
    await cleanup();
  }
});
