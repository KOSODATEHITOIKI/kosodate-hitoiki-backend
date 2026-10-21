import { assert, assertEquals, assertRejects } from "@std/assert";
import { callModeration, callModerationImage } from "./openai.ts";
import { ModerationUnavailableError } from "./types.ts";

/** 判定に使う、すべてのカテゴリ（テキスト）。 */
const ALL_TEXT_SCORES = {
  "harassment": 0.1,
  "harassment/threatening": 0.01,
  "hate": 0.01,
  "hate/threatening": 0.0,
  "self-harm": 0.0,
  "self-harm/intent": 0.0,
  "self-harm/instructions": 0.0,
  "violence": 0.02,
};

const KEY = "sk-test-secret-key-12345";
const TEXT = "とても秘密の本文です";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status });
}

async function rejection(fetchFn: typeof fetch, apiKey: string | undefined = KEY) {
  return await assertRejects(
    () => callModeration(TEXT, { apiKey, fetchFn, timeoutMs: 50 }),
    ModerationUnavailableError,
  );
}

function assertNoLeak(e: Error) {
  assert(!e.message.includes(KEY), "APIキーが例外メッセージに含まれている");
  assert(!e.message.includes(TEXT), "本文が例外メッセージに含まれている");
}

Deno.test("成功時は category_scores を返し、認証ヘッダとモデルを送る", async () => {
  let seen: { headers: HeadersInit | undefined; body: string } | undefined;
  const fetchFn: typeof fetch = (_url, init) => {
    seen = { headers: init?.headers, body: String(init?.body) };
    return Promise.resolve(jsonResponse({ results: [{ category_scores: ALL_TEXT_SCORES }] }));
  };
  const scores = await callModeration(TEXT, { apiKey: KEY, fetchFn });
  assertEquals(scores, ALL_TEXT_SCORES);
  assertEquals((seen!.headers as Record<string, string>).Authorization, `Bearer ${KEY}`);
  assertEquals(JSON.parse(seen!.body).model, "omni-moderation-latest");
});

Deno.test("APIキー未設定は ModerationUnavailableError", async () => {
  const e = await rejection(() => Promise.reject(new Error("呼ばれない")), undefined);
  assertNoLeak(e);
});

Deno.test("通信失敗：元の例外にキー・本文が含まれても外へ漏らさない", async () => {
  const e = await rejection(() => Promise.reject(new Error(`boom ${KEY} ${TEXT}`)));
  assertNoLeak(e);
});

Deno.test("5xx・429・401 は ModerationUnavailableError（ステータスのみ残す）", async () => {
  for (const status of [500, 429, 401]) {
    const e = await rejection(() =>
      Promise.resolve(jsonResponse({ error: { message: `${KEY} ${TEXT}` } }, status))
    );
    assertNoLeak(e);
    assert(e.message.includes(String(status)));
  }
});

Deno.test("想定外の応答形式は ModerationUnavailableError", async () => {
  for (const body of [{}, { results: [] }, { results: [{}] }]) {
    const e = await rejection(() => Promise.resolve(jsonResponse(body)));
    assertNoLeak(e);
  }
});

Deno.test("JSONでない応答は ModerationUnavailableError", async () => {
  const e = await rejection(() =>
    Promise.resolve(new Response("<html>gateway</html>", { status: 200 }))
  );
  assertNoLeak(e);
});

Deno.test("タイムアウトは ModerationUnavailableError", async () => {
  const fetchFn: typeof fetch = (_url, init) =>
    new Promise((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () =>
        reject(new DOMException("aborted", "AbortError")));
    });
  const e = await rejection(fetchFn);
  assertNoLeak(e);
});

Deno.test("不完全なスコア（空・カテゴリの欠け・数でない・範囲外）は、許可ではなく ModerationUnavailableError", async () => {
  const withoutHarassment = Object.fromEntries(
    Object.entries(ALL_TEXT_SCORES).filter(([k]) => k !== "harassment"),
  );
  const bad: unknown[] = [
    {},
    [],
    withoutHarassment,
    { ...ALL_TEXT_SCORES, "self-harm": "0.9" },
    { ...ALL_TEXT_SCORES, "self-harm": null },
    { ...ALL_TEXT_SCORES, "harassment": 1.5 },
    { ...ALL_TEXT_SCORES, "harassment": -0.1 },
    { ...ALL_TEXT_SCORES, "hate": Number.NaN },
  ];
  for (const scores of bad) {
    const e = await rejection(() =>
      Promise.resolve(jsonResponse({ results: [{ category_scores: scores }] }))
    );
    assertNoLeak(e);
  }
});

Deno.test("画像：判定に使うカテゴリが欠けた応答は ModerationUnavailableError。そろっていれば返す（sexual/minorsは、なくてもよいが、あれば検証）", async () => {
  const ok = { "sexual": 0.0, "violence/graphic": 0.0, "self-harm/instructions": 0.0 };
  const image = (scores: unknown) =>
    callModerationImage(new Uint8Array([1, 2, 3]), "image/png", {
      apiKey: KEY,
      fetchFn: () => Promise.resolve(jsonResponse({ results: [{ category_scores: scores }] })),
    });
  assertEquals(await image(ok), ok);
  assertEquals(await image({ ...ok, "sexual/minors": 0.0 }), { ...ok, "sexual/minors": 0.0 });
  await assertRejects(() => image({ ...ok, "sexual/minors": "x" }), ModerationUnavailableError);
  await assertRejects(() => image({ ...ok, "sexual": 2 }), ModerationUnavailableError);
  await assertRejects(
    () =>
      callModerationImage(new Uint8Array([1, 2, 3]), "image/png", {
        apiKey: KEY,
        fetchFn: () => Promise.resolve(jsonResponse({ results: [{ category_scores: {} }] })),
      }),
    ModerationUnavailableError,
  );
});
