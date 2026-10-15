import { assert, assertEquals } from "@std/assert";
import {
  avatarHandler,
  changeNicknameHandler,
  createProfileHandler,
  drainPendingDeletions,
  updateProfileHandler,
} from "./handlers.ts";
import {
  imageRequest,
  JPEG,
  JPEG_WITH_GPS,
  jsonRequest,
  makeFake,
  PNG,
  USER_ID,
} from "./test_helpers.ts";
import { DbError } from "./types.ts";

const validCreate = {
  nickname: "はなこ",
  bio: "よろしくお願いします",
  child_age_range: "0〜1歳",
  terms_version: "2026-10",
};

async function errorCode(res: Response): Promise<string> {
  return (await res.json()).error.code;
}

// --- プロフィール登録 ---

Deno.test("登録：未ログインは 401", async () => {
  const f = makeFake({ loggedIn: false });
  const res = await createProfileHandler(f.deps)(jsonRequest("POST", validCreate));
  assertEquals(res.status, 401);
  assertEquals(f.calls.createProfile.length, 0);
});

Deno.test("登録：成功すると 201。規約版とチェック済みの本文が保存される", async () => {
  const f = makeFake();
  const res = await createProfileHandler(f.deps)(
    jsonRequest("POST", { ...validCreate, nickname: "  はなこ " }),
  );
  assertEquals(res.status, 201);
  assertEquals(await res.json(), { id: USER_ID, support_notice: false });
  assertEquals(f.calls.createProfile, [{
    userId: USER_ID,
    nickname: "はなこ",
    bio: "よろしくお願いします",
    childAgeRange: "0〜1歳",
    iconKey: null,
    termsVersion: "2026-10",
  }]);
});

Deno.test("登録：利用規約への同意がなければ 422", async () => {
  const f = makeFake();
  const res = await createProfileHandler(f.deps)(
    jsonRequest("POST", { nickname: "はなこ" }),
  );
  assertEquals(res.status, 422);
  assertEquals(f.calls.createProfile.length, 0);
});

Deno.test("登録：ニックネームの文字数違反は 422 でDBに触れない", async () => {
  const f = makeFake();
  const res = await createProfileHandler(f.deps)(
    jsonRequest("POST", { ...validCreate, nickname: "あ" }),
  );
  assertEquals(res.status, 422);
  assertEquals(await errorCode(res), "VALIDATION_FAILED");
  assertEquals(f.calls.createProfile.length, 0);
});

Deno.test("登録：自己紹介に電話番号があれば 422 で保存せず、外部APIにも送らない", async () => {
  const f = makeFake();
  const res = await createProfileHandler(f.deps)(
    jsonRequest("POST", { ...validCreate, bio: "連絡は090-1234-5678まで" }),
  );
  assertEquals(res.status, 422);
  assertEquals(await errorCode(res), "MODERATION_REJECTED");
  assertEquals(f.calls.createProfile.length, 0);
  // 個人情報を含む自己紹介は、外部APIへ送らない（問題のないニックネームだけが判定に回る）。
  assert(f.calls.moderated.every((t) => !t.includes("090")));
});

Deno.test("登録：境界域は 409（確認必須）。confirmed=true の再送で保存される", async () => {
  const f = makeFake({ scores: { harassment: 0.6 } });
  const first = await createProfileHandler(f.deps)(jsonRequest("POST", validCreate));
  assertEquals(first.status, 409);
  assertEquals(await errorCode(first), "MODERATION_CONFIRM_REQUIRED");
  assertEquals(f.calls.createProfile.length, 0);

  const second = await createProfileHandler(f.deps)(
    jsonRequest("POST", { ...validCreate, confirmed: true }),
  );
  assertEquals(second.status, 201);
  assertEquals(f.calls.createProfile.length, 1);
});

Deno.test("登録：外部APIの障害では 503 で保存しない", async () => {
  const f = makeFake({ moderationDown: true });
  const res = await createProfileHandler(f.deps)(jsonRequest("POST", validCreate));
  assertEquals(res.status, 503);
  assertEquals(await errorCode(res), "MODERATION_UNAVAILABLE");
  assertEquals(f.calls.createProfile.length, 0);
});

Deno.test("登録：再送（同じ名前で作成済み）は重複せず 200", async () => {
  const f = makeFake({ createResult: "exists" });
  const res = await createProfileHandler(f.deps)(jsonRequest("POST", validCreate));
  assertEquals(res.status, 200);
});

Deno.test("登録：別の名前で作成済みなら 409 CONFLICT", async () => {
  const f = makeFake({ createResult: "conflict" });
  const res = await createProfileHandler(f.deps)(jsonRequest("POST", validCreate));
  assertEquals(res.status, 409);
  assertEquals(await errorCode(res), "CONFLICT");
});

Deno.test("登録：他の人と同じ名前（一意制約違反）は 409、生のDBメッセージは返さない", async () => {
  const f = makeFake({ dbError: new DbError("23505") });
  const res = await createProfileHandler(f.deps)(jsonRequest("POST", validCreate));
  assertEquals(res.status, 409);
  assertEquals(await errorCode(res), "CONFLICT");
});

Deno.test("登録：旧名の予約中は 422 で、利用者向けの文言だけ返す", async () => {
  const f = makeFake({ dbError: new DbError("P0001", "この名前は現在使用できません") });
  const res = await createProfileHandler(f.deps)(jsonRequest("POST", validCreate));
  assertEquals(res.status, 422);
  assertEquals((await res.json()).error.message, "この名前は現在使用できません");
});

Deno.test("登録：想定外のDBエラーは 500。本文・内部情報を含めない", async () => {
  const f = makeFake({ dbError: new DbError("XX000") });
  const res = await createProfileHandler(f.deps)(jsonRequest("POST", validCreate));
  assertEquals(res.status, 500);
  const text = JSON.stringify(await res.json());
  assert(!text.includes("はなこ") && !text.includes("よろしくお願いします"));
});

Deno.test("登録：POST以外は 405、プリフライトは 204", async () => {
  const f = makeFake();
  const h = createProfileHandler(f.deps);
  assertEquals((await h(new Request("http://localhost/fn", { method: "GET" }))).status, 405);
  assertEquals((await h(new Request("http://localhost/fn", { method: "OPTIONS" }))).status, 204);
});

// --- ニックネーム変更 ---

Deno.test("ニックネーム変更：成功", async () => {
  const f = makeFake();
  const res = await changeNicknameHandler(f.deps)(jsonRequest("POST", { nickname: "あたらしい" }));
  assertEquals(res.status, 200);
  assertEquals(f.calls.changeNickname, ["あたらしい"]);
});

Deno.test("ニックネーム変更：攻撃的な名前は 422 で変更しない", async () => {
  const f = makeFake();
  const res = await changeNicknameHandler(f.deps)(jsonRequest("POST", { nickname: "死ね" }));
  assertEquals(res.status, 422);
  assertEquals(await errorCode(res), "MODERATION_REJECTED");
  assertEquals(f.calls.changeNickname.length, 0);
});

Deno.test("ニックネーム変更：30日制限は 422 で文言を返す", async () => {
  const f = makeFake({
    dbError: new DbError("P0001", "ニックネームは30日に1回まで変更できます"),
  });
  const res = await changeNicknameHandler(f.deps)(jsonRequest("POST", { nickname: "あたらしい" }));
  assertEquals(res.status, 422);
  assertEquals((await res.json()).error.message, "ニックネームは30日に1回まで変更できます");
});

Deno.test("ニックネーム変更：プロフィール未登録は 404", async () => {
  const f = makeFake({ dbError: new DbError("NOT_FOUND") });
  const res = await changeNicknameHandler(f.deps)(jsonRequest("POST", { nickname: "あたらしい" }));
  assertEquals(res.status, 404);
});

// --- プロフィール更新 ---

Deno.test("更新：空の更新は 422", async () => {
  const f = makeFake();
  const res = await updateProfileHandler(f.deps)(jsonRequest("PATCH", {}));
  assertEquals(res.status, 422);
});

Deno.test("更新：自己紹介は送信前チェックを通してから保存する", async () => {
  const f = makeFake();
  const ok = await updateProfileHandler(f.deps)(jsonRequest("PATCH", { bio: "元気です" }));
  assertEquals(ok.status, 200);
  assertEquals(f.calls.updateProfile, [{ bio: "元気です" }]);
  assertEquals(f.calls.moderated, ["元気です"]);

  const ng = await updateProfileHandler(f.deps)(
    jsonRequest("PATCH", { bio: "メールは taro@example.com" }),
  );
  assertEquals(ng.status, 422);
  assertEquals(f.calls.updateProfile.length, 1);
});

Deno.test("更新：イラストを選ぶと、アップロード画像を削除する", async () => {
  const f = makeFake({ avatarPath: `${USER_ID}/old.png` });
  const res = await updateProfileHandler(f.deps)(jsonRequest("PATCH", { icon_key: "bear_01" }));
  assertEquals(res.status, 200);
  assertEquals(f.calls.updateProfile, [{ icon_key: "bear_01" }]);
  assertEquals(f.calls.removed, [`${USER_ID}/old.png`]);
});

Deno.test("更新：自己紹介の更新失敗時は旧画像を消さない", async () => {
  const f = makeFake({ avatarPath: `${USER_ID}/old.png`, dbError: new DbError("XX000") });
  const res = await updateProfileHandler(f.deps)(jsonRequest("PATCH", { icon_key: "bear_01" }));
  assertEquals(res.status, 500);
  assertEquals(f.calls.removed, []);
});

// --- アカウント画像 ---

Deno.test("画像：成功すると保存し、旧画像を削除する", async () => {
  const f = makeFake({ avatarPath: `${USER_ID}/old.png` });
  const res = await avatarHandler(f.deps)(imageRequest("PUT", PNG, "image/png"));
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { avatar_path: `${USER_ID}/fixed-id.png` });
  assertEquals(f.calls.uploaded, [`${USER_ID}/fixed-id.png`]);
  assertEquals(f.calls.setAvatarPath, [`${USER_ID}/fixed-id.png`]);
  assertEquals(f.calls.removed, [`${USER_ID}/old.png`]);
  assertEquals(f.calls.moderatedImages, 1);
});

Deno.test("画像：形式（Content-Type）が許可外なら 422", async () => {
  const f = makeFake();
  const res = await avatarHandler(f.deps)(imageRequest("PUT", PNG, "image/gif"));
  assertEquals(res.status, 422);
  assertEquals(f.calls.uploaded.length, 0);
});

Deno.test("画像：Content-Typeと中身が違うファイルは 422（拡張子偽装）", async () => {
  const f = makeFake();
  const res = await avatarHandler(f.deps)(imageRequest("PUT", PNG, "image/jpeg"));
  assertEquals(res.status, 422);
  assertEquals(f.calls.moderatedImages, 0);
  assertEquals(f.calls.uploaded.length, 0);
});

Deno.test("画像：2MBを超えると 422", async () => {
  const f = makeFake();
  const big = new Uint8Array(2 * 1024 * 1024 + 1);
  big.set(JPEG);
  const res = await avatarHandler(f.deps)(imageRequest("PUT", big, "image/jpeg"));
  assertEquals(res.status, 422);
  assertEquals(f.calls.uploaded.length, 0);
});

Deno.test("画像：不適切と判定されたら 422 で保存しない", async () => {
  const f = makeFake({ imageScores: { sexual: 0.9 } });
  const res = await avatarHandler(f.deps)(imageRequest("PUT", JPEG, "image/jpeg"));
  assertEquals(res.status, 422);
  assertEquals(await errorCode(res), "MODERATION_REJECTED");
  assertEquals(f.calls.uploaded.length, 0);
  assertEquals(f.calls.setAvatarPath.length, 0);
});

Deno.test("画像：外部APIの障害では 503 で保存しない", async () => {
  const f = makeFake({ moderationDown: true });
  const res = await avatarHandler(f.deps)(imageRequest("PUT", JPEG, "image/jpeg"));
  assertEquals(res.status, 503);
  assertEquals(f.calls.uploaded.length, 0);
});

Deno.test("画像：DB更新に失敗したら 500。アップロード済みの画像は、回収用の記録から回収される", async () => {
  const f = makeFake({ setAvatarError: new DbError("XX000") });
  const res = await avatarHandler(f.deps)(imageRequest("PUT", PNG, "image/png"));
  assertEquals(res.status, 500);
  assertEquals(f.calls.uploaded, [`${USER_ID}/fixed-id.png`]);
  assertEquals(f.state.reserved, [`${USER_ID}/fixed-id.png`]);
});

Deno.test("画像：保存先は必ず本人のフォルダ配下", async () => {
  const f = makeFake();
  await avatarHandler(f.deps)(imageRequest("PUT", JPEG, "image/jpeg"));
  assert(f.calls.uploaded.every((p) => p.startsWith(`${USER_ID}/`)));
});

Deno.test("画像：DELETEでアップロード画像を外し、ファイルも削除する", async () => {
  const f = makeFake({ avatarPath: `${USER_ID}/old.png` });
  const res = await avatarHandler(f.deps)(new Request("http://localhost/fn", { method: "DELETE" }));
  assertEquals(res.status, 200);
  assertEquals(f.calls.setAvatarPath, [null]);
  assertEquals(f.calls.removed, [`${USER_ID}/old.png`]);
});

Deno.test("画像：未ログインは 401", async () => {
  const f = makeFake({ loggedIn: false });
  const res = await avatarHandler(f.deps)(imageRequest("PUT", PNG, "image/png"));
  assertEquals(res.status, 401);
  assertEquals(f.calls.moderatedImages, 0);
});

Deno.test("登録：新規登録の停止中は 429（RATE_LIMITED・signup_halted）。DBの文言は返さない", async () => {
  const f = makeFake({ dbError: new DbError("SIGNUP_HALTED") });
  const res = await createProfileHandler(f.deps)(jsonRequest("POST", validCreate));
  assertEquals(res.status, 429);
  const e = (await res.json()).error;
  assertEquals(e.code, "RATE_LIMITED");
  assertEquals(e.details.reason, "signup_halted");
});

// --- 公開前レビューへの対処 ---

const contains = (bytes: Uint8Array, text: string) =>
  new TextDecoder("latin1").decode(bytes).includes(text);

Deno.test("画像：位置情報（GPS）などのメタデータを除いた画像だけを保存し、同じ画像を確認に回す", async () => {
  const f = makeFake();
  assert(contains(JPEG_WITH_GPS, "GPSLatitude"), "テストの画像にGPSが入っていない");
  const res = await avatarHandler(f.deps)(imageRequest("PUT", JPEG_WITH_GPS, "image/jpeg"));
  assertEquals(res.status, 200);
  assertEquals(f.calls.uploadedBytes.length, 1);
  assert(!contains(f.calls.uploadedBytes[0], "GPS"), "保存された画像に位置情報が残っている");
  assert(!contains(f.calls.uploadedBytes[0], "Exif"));
  // 確認に回す画像も、実際に保存する画像と同じ
  assertEquals(f.calls.imagesChecked[0], f.calls.uploadedBytes[0]);
});

Deno.test("画像：構造が壊れている・画像データのない画像は 422。確認も保存もしない", async () => {
  for (
    const [bytes, type] of [
      [new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]), "image/jpeg"], // 途中で切れたJPEG
      [new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]), "image/png"],
    ] as const
  ) {
    const f = makeFake();
    const res = await avatarHandler(f.deps)(imageRequest("PUT", bytes, type));
    assertEquals(res.status, 422);
    assertEquals(f.calls.moderatedImages, 0);
    assertEquals(f.calls.preflight, []);
    assertEquals(f.calls.uploaded.length, 0);
  }
});

Deno.test("外部API前の確認：画像は preflight(image) を通ってから確認する。上限なら 429 で外部APIも保存もしない", async () => {
  const ok = makeFake();
  await avatarHandler(ok.deps)(imageRequest("PUT", JPEG, "image/jpeg"));
  assertEquals(ok.calls.preflight, ["image"]);

  const limited = makeFake({
    preflightError: new DbError("REQUEST_LIMITED", "2026-10-15T12:10:00.000Z"),
  });
  const res = await avatarHandler(limited.deps)(imageRequest("PUT", JPEG, "image/jpeg"));
  assertEquals(res.status, 429);
  const e = (await res.json()).error;
  assertEquals(e.code, "RATE_LIMITED");
  assertEquals(e.details, { reason: "request_limit", retry_at: "2026-10-15T12:10:00.000Z" });
  assertEquals(limited.calls.moderatedImages, 0);
  assertEquals(limited.calls.uploaded.length, 0);
});

Deno.test("外部API前の確認：プロフィールの登録・ニックネーム変更・更新は、確認の前に preflight(profile) を通る", async () => {
  const f = makeFake();
  await createProfileHandler(f.deps)(jsonRequest("POST", validCreate));
  await changeNicknameHandler(f.deps)(jsonRequest("POST", { nickname: "あたらしい" }));
  await updateProfileHandler(f.deps)(jsonRequest("PATCH", { bio: "こんにちは" }));
  assertEquals(f.calls.preflight, ["profile", "profile", "profile"]);

  for (
    const call of [
      (d: ReturnType<typeof makeFake>["deps"]) =>
        createProfileHandler(d)(jsonRequest("POST", validCreate)),
      (d: ReturnType<typeof makeFake>["deps"]) =>
        changeNicknameHandler(d)(jsonRequest("POST", { nickname: "あたらしい" })),
      (d: ReturnType<typeof makeFake>["deps"]) =>
        updateProfileHandler(d)(jsonRequest("PATCH", { bio: "こんにちは" })),
    ]
  ) {
    const limited = makeFake({ preflightError: new DbError("REQUEST_LIMITED") });
    assertEquals((await call(limited.deps)).status, 429);
    assertEquals(limited.calls.moderated, [], "上限のとき外部APIを呼んだ");
  }
});

Deno.test("画像の削除：失敗しても操作は成功するが、削除待ちが残り、あとで必ず削除される", async () => {
  const f = makeFake({ avatarPath: `${USER_ID}/old.png`, removeFails: true });
  const res = await avatarHandler(f.deps)(imageRequest("PUT", PNG, "image/png"));
  assertEquals(res.status, 200); // 利用者の操作は成功する
  // 旧画像は削除待ちに残る（失敗の記録だけで、待ちから外れない）
  assertEquals(f.state.pendingDeletions, [`${USER_ID}/old.png`]);
  assert(f.calls.finishedDeletions.some((d) => d.path === `${USER_ID}/old.png` && !d.ok));
  assertEquals(f.calls.removed, []);

  // 障害が直ったあとの再試行（次の呼び出し・storage-cleanup）で、削除される
  const recovered = makeFake({ removeFails: false });
  recovered.state.pendingDeletions = [...f.state.pendingDeletions];
  assertEquals(await drainPendingDeletions(recovered.deps), 1);
  assertEquals(recovered.calls.removed, [`${USER_ID}/old.png`]);
  assertEquals(recovered.state.pendingDeletions, []);
});

Deno.test("画像の削除：イラストへの変更・画像の削除（DELETE）でも、失敗したら削除待ちが残る", async () => {
  const a = makeFake({ avatarPath: `${USER_ID}/old.png`, removeFails: true });
  assertEquals(
    (await updateProfileHandler(a.deps)(jsonRequest("PATCH", { icon_key: "bear_01" }))).status,
    200,
  );
  assertEquals(a.state.pendingDeletions, [`${USER_ID}/old.png`]);

  const b = makeFake({ avatarPath: `${USER_ID}/old.png`, removeFails: true });
  const res = await avatarHandler(b.deps)(new Request("http://localhost/fn", { method: "DELETE" }));
  assertEquals(res.status, 200);
  assertEquals(b.state.pendingDeletions, [`${USER_ID}/old.png`]);
});

Deno.test("画像の回収：アップロードの前に回収用の記録を残し、結び付けに成功すると記録は消える", async () => {
  const f = makeFake();
  const res = await avatarHandler(f.deps)(imageRequest("PUT", PNG, "image/png"));
  assertEquals(res.status, 200);
  assertEquals(f.calls.reserved, [`${USER_ID}/fixed-id.png`]);
  assertEquals(f.state.reserved, [], "結び付けた画像の記録が残っている");
  assertEquals(f.calls.removed, [], "使用中の画像を削除してはいけない");
});

Deno.test("画像の回収：回収用の記録を残せない（DB障害）ときは、アップロードしない。画像は取り残されない", async () => {
  const f = makeFake({ reserveFails: true });
  const res = await avatarHandler(f.deps)(imageRequest("PUT", PNG, "image/png"));
  assertEquals(res.status, 500);
  assertEquals(f.calls.uploaded, [], "記録なしでアップロードした");
  assertEquals(f.calls.setAvatarPath, []);
});

Deno.test("画像の回収：結び付けに失敗しても、画像を直接は消さず、回収用の記録を残す（成否が分からない失敗に備える）", async () => {
  const f = makeFake({ setAvatarError: new DbError("XX000") });
  const res = await avatarHandler(f.deps)(imageRequest("PUT", PNG, "image/png"));
  assertEquals(res.status, 500);
  assertEquals(f.calls.uploaded, [`${USER_ID}/fixed-id.png`]);
  // 記録が残るので、DBが回復すれば猶予（10分）のあとに回収される。直接削除はしない
  // （結び付けに成功していた場合に、使用中の画像を消してしまわないため）
  assertEquals(f.state.reserved, [`${USER_ID}/fixed-id.png`]);
  assertEquals(f.calls.removed, []);
});
