import {
  errorResponse,
  jsonResponse,
  methodNotAllowed,
  preflight,
  readJsonObject,
  unauthenticated,
} from "../http.ts";
import { checkImage } from "../moderation/check.ts";
import { responseForDecision, responseForError } from "../moderation/http.ts";
import { moderateAndSave } from "../moderation/moderate_and_save.ts";
import { DbError, type ProfileDeps } from "./types.ts";
import {
  validateBio,
  validateChildAgeRange,
  type Validated,
  validateIconKey,
  validateNickname,
  validateTermsVersion,
} from "./validate.ts";

const invalidRequest = () =>
  errorResponse(422, "VALIDATION_FAILED", "リクエストの形式が正しくありません。");

function invalid(v: Extract<Validated<unknown>, { ok: false }>): Response {
  return errorResponse(422, "VALIDATION_FAILED", v.message, { field: v.field, limit: v.limit });
}

/** DB・外部APIのエラーをAPI契約のレスポンスへ。内部エラーの詳細・本文は返さない。 */
function errorToResponse(e: unknown): Response {
  const unavailable = responseForError(e);
  if (unavailable) return unavailable;
  if (e instanceof DbError) {
    // 一意制約違反：同じ名前を他の人が使っている。
    if (e.code === "23505") {
      return errorResponse(
        409,
        "CONFLICT",
        "このニックネームは使えません。別の名前を入力してください。",
      );
    }
    if (e.code === "NOT_FOUND") {
      return errorResponse(404, "NOT_FOUND", "プロフィールが見つかりません。");
    }
    // トリガーによる業務ルール違反（30日制限・旧名の予約）。
    if (e.code === "P0001") {
      return errorResponse(422, "VALIDATION_FAILED", e.hint ?? "入力内容を確認してください。");
    }
  }
  console.error("profile function failed", e instanceof Error ? e.name : "unknown");
  return errorResponse(
    500,
    "INTERNAL_ERROR",
    "処理に失敗しました。しばらくしてからもう一度お試しください。",
  );
}

/** POST：プロフィールの新規登録（ニックネーム・自己紹介は送信前チェック、利用規約同意を記録）。 */
export function createProfileHandler(deps: ProfileDeps) {
  return async (req: Request): Promise<Response> => {
    const early = preflight(req);
    if (early) return early;
    if (req.method !== "POST") return methodNotAllowed();
    const userId = await deps.authenticate(req);
    if (!userId) return unauthenticated();
    const body = await readJsonObject(req);
    if (!body) return invalidRequest();

    const nickname = validateNickname(body.nickname);
    if (!nickname.ok) return invalid(nickname);
    const bio = validateBio(body.bio);
    if (!bio.ok) return invalid(bio);
    const age = validateChildAgeRange(body.child_age_range);
    if (!age.ok) return invalid(age);
    const icon = validateIconKey(body.icon_key);
    if (!icon.ok) return invalid(icon);
    const terms = validateTermsVersion(body.terms_version);
    if (!terms.ok) return invalid(terms);

    try {
      const { result, saved } = await moderateAndSave(
        { nickname: nickname.value, bio: bio.value ?? "" },
        deps.moderation,
        { confirmed: body.confirmed === true },
        (verified) =>
          deps.db.createProfile({
            userId,
            nickname: verified.nickname,
            bio: verified.bio === "" ? null : verified.bio,
            childAgeRange: age.value,
            iconKey: icon.value,
            termsVersion: terms.value,
          }),
      );
      const blocked = responseForDecision(result);
      if (blocked) return blocked;
      if (saved === "conflict") {
        return errorResponse(409, "CONFLICT", "プロフィールはすでに登録されています。");
      }
      return jsonResponse(saved === "created" ? 201 : 200, {
        id: userId,
        support_notice: result.supportNotice,
      });
    } catch (e) {
      return errorToResponse(e);
    }
  };
}

/** POST：ニックネームの変更（送信前チェック。30日の変更制限・旧名の予約はDBが強制）。 */
export function changeNicknameHandler(deps: ProfileDeps) {
  return async (req: Request): Promise<Response> => {
    const early = preflight(req);
    if (early) return early;
    if (req.method !== "POST") return methodNotAllowed();
    const userId = await deps.authenticate(req);
    if (!userId) return unauthenticated();
    const body = await readJsonObject(req);
    if (!body) return invalidRequest();

    const nickname = validateNickname(body.nickname);
    if (!nickname.ok) return invalid(nickname);

    try {
      const { result } = await moderateAndSave(
        { nickname: nickname.value },
        deps.moderation,
        { confirmed: body.confirmed === true },
        (verified) => deps.db.changeNickname(userId, verified.nickname),
      );
      const blocked = responseForDecision(result);
      if (blocked) return blocked;
      return jsonResponse(200, { nickname: nickname.value, support_notice: result.supportNotice });
    } catch (e) {
      return errorToResponse(e);
    }
  };
}

/** PATCH：自己紹介・子どもの年齢帯・イラスト選択の更新。自己紹介は送信前チェック。 */
export function updateProfileHandler(deps: ProfileDeps) {
  return async (req: Request): Promise<Response> => {
    const early = preflight(req);
    if (early) return early;
    if (req.method !== "PATCH") return methodNotAllowed();
    const userId = await deps.authenticate(req);
    if (!userId) return unauthenticated();
    const body = await readJsonObject(req);
    if (!body) return invalidRequest();

    const patch: {
      bio?: string | null;
      child_age_range?: string | null;
      icon_key?: string | null;
    } = {};
    if ("bio" in body) {
      const v = validateBio(body.bio);
      if (!v.ok) return invalid(v);
      patch.bio = v.value;
    }
    if ("child_age_range" in body) {
      const v = validateChildAgeRange(body.child_age_range);
      if (!v.ok) return invalid(v);
      patch.child_age_range = v.value;
    }
    if ("icon_key" in body) {
      const v = validateIconKey(body.icon_key);
      if (!v.ok) return invalid(v);
      patch.icon_key = v.value;
    }
    if (Object.keys(patch).length === 0) return invalidRequest();

    try {
      // イラストを選ぶと、アップロード画像は外れる（どちらか一方）。旧画像は保存後に削除する。
      const oldAvatar = patch.icon_key ? await deps.db.getAvatarPath(userId) : null;

      const { result } = await moderateAndSave(
        { bio: patch.bio ?? "" },
        deps.moderation,
        { confirmed: body.confirmed === true },
        () => deps.db.updateProfile(userId, patch),
      );
      const blocked = responseForDecision(result);
      if (blocked) return blocked;

      if (oldAvatar) await removeQuietly(deps, oldAvatar);
      return jsonResponse(200, { support_notice: result.supportNotice });
    } catch (e) {
      return errorToResponse(e);
    }
  };
}

const IMAGE_TYPES: Readonly<Record<string, string>> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
};
export const AVATAR_MAX_BYTES = 2 * 1024 * 1024;

/** 宣言されたContent-Typeと、ファイル先頭のバイト列（マジックナンバー）が一致するか。 */
export function matchesImageSignature(bytes: Uint8Array, mimeType: string): boolean {
  const startsWith = (sig: number[], offset = 0) => sig.every((b, i) => bytes[offset + i] === b);
  switch (mimeType) {
    case "image/jpeg":
      return startsWith([0xff, 0xd8, 0xff]);
    case "image/png":
      return startsWith([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    case "image/webp": // "RIFF" ???? "WEBP"
      return startsWith([0x52, 0x49, 0x46, 0x46]) && startsWith([0x57, 0x45, 0x42, 0x50], 8);
    default:
      return false;
  }
}

async function removeQuietly(deps: ProfileDeps, path: string): Promise<void> {
  try {
    await deps.storage.remove(path);
  } catch {
    // 旧画像の削除失敗は利用者の操作を失敗させない（孤立ファイルは定期清掃で回収する想定）。
    console.error("avatar cleanup failed");
  }
}

/** PUT：画像をアップロードして設定（確認後にサーバーが保存）／DELETE：アップロード画像を外す。 */
export function avatarHandler(deps: ProfileDeps) {
  return async (req: Request): Promise<Response> => {
    const early = preflight(req);
    if (early) return early;
    if (req.method !== "PUT" && req.method !== "DELETE") return methodNotAllowed();
    const userId = await deps.authenticate(req);
    if (!userId) return unauthenticated();

    try {
      if (req.method === "DELETE") {
        const old = await deps.db.getAvatarPath(userId);
        if (old) {
          await deps.db.setAvatarPath(userId, null);
          await removeQuietly(deps, old);
        }
        return jsonResponse(200, { avatar_path: null });
      }

      const mimeType = (req.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
      const ext = IMAGE_TYPES[mimeType];
      if (!ext) {
        return errorResponse(
          422,
          "VALIDATION_FAILED",
          "画像はJPEG・PNG・WebPのいずれかにしてください。",
          {
            field: "image",
          },
        );
      }
      const declared = Number(req.headers.get("content-length") ?? "0");
      const tooLarge = () =>
        errorResponse(422, "VALIDATION_FAILED", "画像は2MB以内にしてください。", {
          field: "image",
          limit: AVATAR_MAX_BYTES,
        });
      if (declared > AVATAR_MAX_BYTES) return tooLarge();

      const bytes = new Uint8Array(await req.arrayBuffer());
      if (bytes.length > AVATAR_MAX_BYTES) return tooLarge();
      if (bytes.length === 0 || !matchesImageSignature(bytes, mimeType)) {
        return errorResponse(422, "VALIDATION_FAILED", "画像ファイルを読み取れませんでした。", {
          field: "image",
        });
      }

      // 保存前に確認する。不適切なら保存しない。API障害時は保存しない（ModerationUnavailableError）。
      const blocked = responseForDecision(await checkImage(bytes, mimeType, deps.imageModeration));
      if (blocked) return blocked;

      const path = `${userId}/${(deps.newId ?? crypto.randomUUID.bind(crypto))()}.${ext}`;
      await deps.storage.upload(path, bytes, mimeType);
      let old: string | null;
      try {
        old = await deps.db.getAvatarPath(userId);
        await deps.db.setAvatarPath(userId, path);
      } catch (e) {
        await removeQuietly(deps, path); // DB更新に失敗したら、アップロード済みの画像を取り消す
        throw e;
      }
      if (old) await removeQuietly(deps, old);
      return jsonResponse(200, { avatar_path: path });
    } catch (e) {
      return errorToResponse(e);
    }
  };
}
