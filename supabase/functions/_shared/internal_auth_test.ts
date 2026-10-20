import { assert, assertEquals } from "@std/assert";
import { jobSecretMatches } from "./internal_auth.ts";

/** console.error の呼び出しを記録する。 */
async function withCapturedErrors<T>(fn: () => Promise<T>): Promise<{ result: T; logs: string[] }> {
  const original = console.error;
  const logs: string[] = [];
  console.error = (...args: unknown[]) => {
    logs.push(args.map(String).join(" "));
  };
  try {
    return { result: await fn(), logs };
  } finally {
    console.error = original;
  }
}

const SECRET = "a".repeat(32) + "b".repeat(32); // テスト用の使い捨ての値

Deno.test("内部ジョブの秘密：一致したときだけ通る。ログは出さない", async () => {
  const { result, logs } = await withCapturedErrors(() => jobSecretMatches(SECRET, SECRET));
  assertEquals(result, true);
  assertEquals(logs, []);
});

Deno.test("内部ジョブの秘密：関数側が未設定なら拒否し、理由（未設定）をログに残す", async () => {
  for (const expected of [undefined, ""]) {
    const { result, logs } = await withCapturedErrors(() => jobSecretMatches(SECRET, expected));
    assertEquals(result, false);
    assertEquals(logs.length, 1);
    assert(logs[0].includes("not set"), logs[0]);
    assert(!logs[0].includes(SECRET), "ログに秘密の値が出ている");
  }
});

Deno.test("内部ジョブの秘密：値が違えば拒否し、文字数だけをログに残す（値は出さない）", async () => {
  const wrong = SECRET + "\n"; // 末尾に改行が混入した場合
  const { result, logs } = await withCapturedErrors(() => jobSecretMatches(wrong, SECRET));
  assertEquals(result, false);
  assertEquals(logs.length, 1);
  assert(logs[0].includes("given_length=65") && logs[0].includes("expected_length=64"), logs[0]);
  assert(!logs[0].includes(SECRET), "ログに秘密の値が出ている");
  assert(!logs[0].includes("aaaa"), "ログに秘密の一部が出ている");
});

Deno.test("内部ジョブの秘密：ヘッダーがない呼び出しは拒否するが、ログは出さない（無関係なアクセス）", async () => {
  for (const given of [null, ""]) {
    const { result, logs } = await withCapturedErrors(() => jobSecretMatches(given, SECRET));
    assertEquals(result, false);
    assertEquals(logs, []);
  }
});
