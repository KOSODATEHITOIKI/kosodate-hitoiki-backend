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
/** 子どもの年齢帯の選択肢（運営が決定・2026-10-21。DBの check 制約と同じ。変えるときは、移行と同時に直す）。 */
export const CHILD_AGE_RANGES = [
  "age_0_1",
  "age_2_3",
  "age_4_6",
  "elementary",
  "junior_high_plus",
] as const;
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

/** 年齢帯は、決まった選択肢だけ（任意。空・nullは未選択）。 */
export function validateChildAgeRange(input: unknown): Validated<string | null> {
  if (input === undefined || input === null || input === "") return { ok: true, value: null };
  if (typeof input !== "string" || !(CHILD_AGE_RANGES as readonly string[]).includes(input)) {
    return fail("child_age_range", "子どもの年齢帯の指定が正しくありません。");
  }
  return { ok: true, value: input };
}

/** アイコンは、形式だけをここで確かめる。決まったアイコン（profile_icons）との照合は、DBの外部キーが行う。 */
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
