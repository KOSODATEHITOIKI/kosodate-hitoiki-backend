import { containsBannedWord } from "./banned_words.ts";
import { normalizeForDetection } from "./normalize.ts";
import { detectPii } from "./pii.ts";
import { evaluateScores, isImageRejected } from "./policy.ts";
import type { CheckDeps, CheckResult, ModerationScores } from "./types.ts";

/**
 * 1つの文章を判定する。
 *
 * 1. 禁止語・個人情報らしき文字列は、外部APIを呼ぶ前にローカルで判定し、該当すれば reject する。
 *    個人情報らしき文字列を外部サービスへ送らないためでもある。
 * 2. 該当しなければ Moderation API で判定する（失敗時は ModerationUnavailableError）。
 *    境界域は confirm（確認済み `confirmed` なら allow）、明確な攻撃・差別・脅迫は reject。
 * 3. 自分や子どもへの危害のほのめかしは止めず、supportNotice で本人にだけ相談先を案内する。
 *
 * 判定結果に本文は含めない。
 */
/**
 * 外部APIを呼ばずにローカルで判定できる範囲（禁止語・個人情報）。該当すれば reject の結果、なければ null。
 * 複数フィールドでは、API障害より先にこの判定を全フィールド分済ませる（確実に止められるものを優先し、
 * 個人情報を含むフィールドを外部へ送らない）。
 */
export function checkLocal(text: string): CheckResult | null {
  const normalized = normalizeForDetection(text);
  const reasons = [
    ...(containsBannedWord(normalized) ? (["banned_word"] as const) : []),
    ...detectPii(text),
  ];
  return reasons.length > 0 ? { decision: "reject", reasons, supportNotice: false } : null;
}

export async function checkText(
  text: string,
  deps: CheckDeps,
  { confirmed = false }: { confirmed?: boolean } = {},
): Promise<CheckResult> {
  if (text.trim() === "") return { decision: "allow", reasons: [], supportNotice: false };

  const local = checkLocal(text);
  if (local) return local;

  const { reject, confirm, supportNotice } = evaluateScores(await deps.moderate(text));
  if (reject.length > 0) return { decision: "reject", reasons: reject, supportNotice };
  if (confirm.length > 0 && !confirmed) {
    return { decision: "confirm", reasons: confirm, supportNotice };
  }
  return { decision: "allow", reasons: [], supportNotice };
}

export interface ImageCheckDeps {
  /** 画像用のModeration API。失敗時は ModerationUnavailableError を投げる。 */
  moderateImage: (bytes: Uint8Array, mimeType: string) => Promise<ModerationScores>;
}

/** アップロード画像の判定。不適切なら reject、それ以外は allow（確認表示は挟まない）。 */
export async function checkImage(
  bytes: Uint8Array,
  mimeType: string,
  deps: ImageCheckDeps,
): Promise<CheckResult> {
  const rejected = isImageRejected(await deps.moderateImage(bytes, mimeType));
  return rejected
    ? { decision: "reject", reasons: ["image_inappropriate"], supportNotice: false }
    : { decision: "allow", reasons: [], supportNotice: false };
}
