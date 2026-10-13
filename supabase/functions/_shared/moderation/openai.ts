import { encodeBase64 } from "@std/encoding/base64";
import { type ModerationScores, ModerationUnavailableError } from "./types.ts";

const ENDPOINT = "https://api.openai.com/v1/moderations";
const MODEL = "omni-moderation-latest";

export interface OpenAiOptions {
  apiKey: string | undefined;
  fetchFn?: typeof fetch;
  timeoutMs?: number;
}

/**
 * OpenAI Moderation APIを呼び、カテゴリ別スコアを返す。
 * 失敗（キー未設定・通信断・タイムアウト・非2xx・想定外の形）はすべて
 * ModerationUnavailableError にまとめる。例外のメッセージには本文・画像・APIキー・
 * 応答本文を含めない（ログへ漏らさないため）。ステータスコードだけ残す。
 */
async function requestModeration(
  input: unknown,
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
    if (!scores || typeof scores !== "object") {
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
  return requestModeration(text, options);
}

/** アップロード画像の確認。画像はdata URLとして送る（保存前の画像を公開URLにしないため）。 */
export function callModerationImage(
  bytes: Uint8Array,
  mimeType: string,
  options: OpenAiOptions,
): Promise<ModerationScores> {
  return requestModeration(
    [{ type: "image_url", image_url: { url: `data:${mimeType};base64,${encodeBase64(bytes)}` } }],
    options,
  );
}
