/**
 * プロフィール入力の検証。文字数は書記素（見た目の1文字）単位で数える（絵文字も1文字、決定済み）。
 * 重複判定に使う正規化（NFKC＋小文字化＋前後空白除去）はDBの normalize_nickname と同じ考え方で、
 * 文字数もNFKC適用後に数えて、全角・半角の違いで数が変わらないようにする。
 */

export type Validated<T> =
  | { ok: true; value: T }
  | { ok: false; field: string; message: string; limit?: number };

export const NICKNAME_MIN = 2;
export const NICKNAME_MAX = 12;
export const BIO_MAX = 100;
const CHILD_AGE_RANGE_MAX = 20;
const ICON_KEY_PATTERN = /^[a-z0-9_-]{1,40}$/;
const TERMS_VERSION_MAX = 40;

const segmenter = new Intl.Segmenter("ja", { granularity: "grapheme" });

export function graphemeCount(text: string): number {
  let n = 0;
  for (const _ of segmenter.segment(text)) n++;
  return n;
}

const fail = (field: string, message: string, limit?: number): Validated<never> => ({
  ok: false,
  field,
  message,
  limit,
});

export function validateNickname(input: unknown): Validated<string> {
  if (typeof input !== "string") return fail("nickname", "ニックネームを入力してください。");
  const nickname = input.trim();
  // 改行・制御文字は使えない。
  if (/[\p{Cc}\p{Zl}\p{Zp}]/u.test(nickname)) {
    return fail("nickname", "ニックネームに使えない文字が含まれています。");
  }
  const count = graphemeCount(nickname.normalize("NFKC"));
  if (count < NICKNAME_MIN || count > NICKNAME_MAX) {
    return fail(
      "nickname",
      `ニックネームは${NICKNAME_MIN}〜${NICKNAME_MAX}文字で入力してください。`,
      NICKNAME_MAX,
    );
  }
  return { ok: true, value: nickname };
}

/** 未指定・空文字は null（設定なし）として扱う。 */
export function validateBio(input: unknown): Validated<string | null> {
  if (input === undefined || input === null) return { ok: true, value: null };
  if (typeof input !== "string") return fail("bio", "自己紹介の形式が正しくありません。");
  const bio = input.trim();
  if (bio === "") return { ok: true, value: null };
  if (graphemeCount(bio) > BIO_MAX) {
    return fail("bio", `自己紹介は${BIO_MAX}文字以内で入力してください。`, BIO_MAX);
  }
  return { ok: true, value: bio };
}

/** 選択肢（年齢帯）は未決定のため、長さだけ検証する。確定後にenum化する。 */
export function validateChildAgeRange(input: unknown): Validated<string | null> {
  if (input === undefined || input === null || input === "") return { ok: true, value: null };
  if (typeof input !== "string" || graphemeCount(input.trim()) > CHILD_AGE_RANGE_MAX) {
    return fail("child_age_range", "子どもの年齢帯の形式が正しくありません。", CHILD_AGE_RANGE_MAX);
  }
  return { ok: true, value: input.trim() };
}

/** イラストのマスタは未決定のため、形式だけ検証する。確定後にマスタと照合する。 */
export function validateIconKey(input: unknown): Validated<string | null> {
  if (input === undefined || input === null || input === "") return { ok: true, value: null };
  if (typeof input !== "string" || !ICON_KEY_PATTERN.test(input)) {
    return fail("icon_key", "アイコンの指定が正しくありません。");
  }
  return { ok: true, value: input };
}

export function validateTermsVersion(input: unknown): Validated<string> {
  if (typeof input !== "string" || input.length < 1 || input.length > TERMS_VERSION_MAX) {
    return fail("terms_version", "利用規約への同意が必要です。");
  }
  return { ok: true, value: input };
}
