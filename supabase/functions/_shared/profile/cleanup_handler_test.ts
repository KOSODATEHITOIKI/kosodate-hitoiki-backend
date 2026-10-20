import { assertEquals } from "@std/assert";
import { storageCleanupHandler } from "./cleanup_handler.ts";

const SECRET = "job-secret-for-test";

function make(secret: string | undefined = SECRET) {
  const calls: number[] = [];
  const handler = storageCleanupHandler({
    // 本番では、DB（Vault）に問い合わせる。ここでは、登録されている秘密と一致するかで代用する。
    verifyJobSecret: (given) =>
      Promise.resolve(secret !== undefined && secret !== "" && given === secret),
    drain: (limit) => {
      calls.push(limit);
      return Promise.resolve(3);
    },
  });
  return { handler, calls };
}

const req = (secret: string | null, method = "POST") =>
  new Request("http://localhost/storage-cleanup", {
    method,
    headers: secret === null ? {} : { "x-job-secret": secret },
  });

Deno.test("画像の削除待ち：秘密がない・違う・未設定のときは 404。何も削除しない", async () => {
  for (
    const [secret, given] of [[SECRET, null], [SECRET, "wrong"], [undefined, "x"], [
      "",
      "",
    ]] as const
  ) {
    const f = make(secret);
    const res = await f.handler(req(given));
    assertEquals(res.status, 404);
    assertEquals((await res.json()).error.code, "NOT_FOUND");
    assertEquals(f.calls, []);
  }
});

Deno.test("画像の削除待ち：正しい秘密なら削除を実行し、削除できた件数を返す。POST以外は 405", async () => {
  const f = make();
  const res = await f.handler(req(SECRET));
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { removed: 3 });
  assertEquals(f.calls, [100]);
  assertEquals((await f.handler(req(SECRET, "GET"))).status, 405);
});
