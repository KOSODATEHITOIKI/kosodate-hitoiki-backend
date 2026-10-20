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

Deno.test("内部ジョブの秘密：DB（Vault）が「正しい」と答えたときだけ通る。ログは出さない", async () => {
  const { result, logs } = await withCapturedErrors(() =>
    jobSecretMatches(SECRET, (g) => Promise.resolve(g === SECRET))
  );
  assertEquals(result, true);
  assertEquals(logs, []);
});

Deno.test("内部ジョブの秘密：DBが「違う」（または未登録）と答えたら拒否し、文字数だけをログに残す", async () => {
  const { result, logs } = await withCapturedErrors(() =>
    jobSecretMatches(SECRET + "\n", () => Promise.resolve(false))
  );
  assertEquals(result, false);
  assertEquals(logs.length, 1);
  assert(logs[0].includes("given_length=65"), logs[0]);
  assert(!logs[0].includes(SECRET), "ログに秘密の値が出ている");
  assert(!logs[0].includes("aaaa"), "ログに秘密の一部が出ている");
});

Deno.test("内部ジョブの秘密：ヘッダーがない呼び出しは、DBに問い合わせず、ログも出さない", async () => {
  let asked = 0;
  for (const given of [null, ""]) {
    const { result, logs } = await withCapturedErrors(() =>
      jobSecretMatches(given, () => {
        asked++;
        return Promise.resolve(true);
      })
    );
    assertEquals(result, false);
    assertEquals(logs, []);
  }
  assertEquals(asked, 0);
});

Deno.test("内部ジョブの秘密：DBに問い合わせられなかったら、安全側（拒否）に倒す。理由はログに残す", async () => {
  const { result, logs } = await withCapturedErrors(() =>
    jobSecretMatches(SECRET, () => Promise.reject(new Error("db down with secret " + SECRET)))
  );
  assertEquals(result, false);
  assertEquals(logs.length, 1);
  assert(logs[0].includes("could not reach the database"), logs[0]);
  assert(!logs[0].includes(SECRET), "ログに秘密の値が出ている");
});
