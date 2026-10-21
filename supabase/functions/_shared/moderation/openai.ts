import { encodeBase64 } from "jsr:@std/encoding@1/base64";
import {
  CONFIRM_THRESHOLDS,
  IMAGE_REJECT_THRESHOLDS,
  REJECT_THRESHOLDS,
  SUPPORT_THRESHOLDS,
} from "./policy.ts";
import { type ModerationScores, ModerationUnavailableError } from "./types.ts";

const ENDPOINT = "https://api.openai.com/v1/moderations";
const MODEL = "omni-moderation-latest";

export interface OpenAiOptions {
  apiKey: string | undefined;
  fetchFn?: typeof fetch;
  timeoutMs?: number;
}

/**
 * 判定に使うカテゴリ（policy.tsの閾値表から作る。閾値表を変えると、ここも変わる）。
 * 応答に、これらのどれかが欠けている、または0〜1の数でない場合は、不完全な応答として扱う。
 * （欠けたカテゴリを0として扱うと、空の応答で「問題なし」と判定され、不適切な内容が保存されてしまう。）
 */
const TEXT_CATEGORIES: readonly string[] = [
  ...new Set([
    ...Object.keys(REJECT_THRESHOLDS),
    ...Object.keys(CONFIRM_THRESHOLDS),
    ...Object.keys(SUPPORT_THRESHOLDS),
  ]),
];
/**
 * 画像の判定に使うカテゴリ。sexual/minors は、OpenAIの仕様でテキストだけが対象とされており、画像の応答に
 * 含まれない可能性があるため、必須にしない（あれば検証する）。必須にすると、含まれない場合に、
 * アカウント画像のアップロードがすべて止まる。
 */
const IMAGE_OPTIONAL = new Set(["sexual/minors"]);
const IMAGE_CATEGORIES: readonly string[] = Object.keys(IMAGE_REJECT_THRESHOLDS)
  .filter((c) => !IMAGE_OPTIONAL.has(c));

const isScore = (v: unknown) => typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 1;

function isCompleteScores(
  scores: unknown,
  required: readonly string[],
  optional: ReadonlySet<string> = new Set(),
): boolean {
  if (!scores || typeof scores !== "object" || Array.isArray(scores)) return false;
  const record = scores as Record<string, unknown>;
  return required.every((category) => isScore(record[category])) &&
    [...optional].every((category) => !(category in record) || isScore(record[category]));
}

/**
 * OpenAI Moderation APIを呼び、カテゴリ別スコアを返す。
 * 失敗（キー未設定・通信断・タイムアウト・非2xx・想定外の形）はすべて
 * ModerationUnavailableError にまとめる。例外のメッセージには本文・画像・APIキー・
 * 応答本文を含めない（ログへ漏らさないため）。ステータスコードだけ残す。
 */
async function requestModeration(
  input: unknown,
  required: readonly string[],
  optional: ReadonlySet<string>,
  { apiKey, fetchFn = fetch, timeoutMs = 5000 }: OpenAiOptions,
): Promise<ModerationScores> {
  if (!apiKey) throw new ModerationUnavailableError("moderation api key is not configured");

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchFn(ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({ model: MODEL, input }),
      signal: controller.signal,
    });
    if (!res.ok) throw new ModerationUnavailableError(`moderation api returned ${res.status}`);

    const scores = (await res.json())?.results?.[0]?.category_scores;
    if (!isCompleteScores(scores, required, optional)) {
      throw new ModerationUnavailableError("moderation api returned an unexpected response");
    }
    return scores as ModerationScores;
  } catch (e) {
    if (e instanceof ModerationUnavailableError) throw e;
    // fetch自体の失敗・タイムアウト・JSON解析失敗。元の例外はキーや本文を含みうるため捨てる。
    throw new ModerationUnavailableError("moderation api request failed");
  } finally {
    clearTimeout(timer);
  }
}

export function callModeration(text: string, options: OpenAiOptions): Promise<ModerationScores> {
  return requestModeration(text, TEXT_CATEGORIES, new Set(), options);
}

/** アップロード画像の確認。画像はdata URLとして送る（保存前の画像を公開URLにしないため）。 */
export function callModerationImage(
  bytes: Uint8Array,
  mimeType: string,
  options: OpenAiOptions,
): Promise<ModerationScores> {
  return requestModeration(
    [{ type: "image_url", image_url: { url: `data:${mimeType};base64,${encodeBase64(bytes)}` } }],
    IMAGE_CATEGORIES,
    IMAGE_OPTIONAL,
    options,
  );
}
