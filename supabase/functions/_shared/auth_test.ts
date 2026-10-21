import { assert, assertEquals, assertRejects } from "@std/assert";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import { bearerToken, readPayload, verifiedUser } from "./auth.ts";
import { errorResponse, guarded } from "./http.ts";

const b64url = (obj: unknown) =>
  btoa(JSON.stringify(obj)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const jwt = (payload: unknown) => `${b64url({ alg: "HS256" })}.${b64url(payload)}.signature`;

const withAuth = (value?: string) =>
  new Request("http://localhost/x", { headers: value ? { Authorization: value } : {} });

Deno.test("Bearerトークン：形式が合うものだけ取り出す（大文字小文字は区別しない）", () => {
  assertEquals(bearerToken(withAuth("Bearer abc.def.ghi")), "abc.def.ghi");
  assertEquals(bearerToken(withAuth("bearer abc")), "abc");
  assertEquals(bearerToken(withAuth()), null);
  assertEquals(bearerToken(withAuth("Basic abc")), null);
  assertEquals(bearerToken(withAuth("Bearer ")), null);
});

Deno.test("JWTの本体：読めればオブジェクト、読めない・オブジェクトでなければ空", () => {
  assertEquals(readPayload(jwt({ aal: "aal2", session_id: "s1" })), {
    aal: "aal2",
    session_id: "s1",
  });
  assertEquals(readPayload("not-a-jwt"), {});
  assertEquals(readPayload("a.@@@.c"), {});
  assertEquals(readPayload(jwt([1, 2])), {}); // 配列は不可
  assertEquals(readPayload(jwt("text")), {});
  assertEquals(readPayload(jwt(null)), {});
});

/** auth.getUser だけを持つ、最小の偽物。 */
function fakeAdmin(
  result: { data: { user: { id: string } | null }; error: unknown } | "throw",
): SupabaseClient {
  return {
    auth: {
      getUser: () =>
        result === "throw"
          ? Promise.reject(new Error("auth down with secret-token"))
          : Promise.resolve(result),
    },
  } as unknown as SupabaseClient;
}

Deno.test("認証：検証できたら、利用者IDと、検証済みトークンのクレームを返す", async () => {
  const token = jwt({ aal: "aal2", session_id: "s1" });
  const user = await verifiedUser(
    fakeAdmin({ data: { user: { id: "u1" } }, error: null }),
    withAuth(`Bearer ${token}`),
  );
  assertEquals(user, { userId: "u1", claims: { aal: "aal2", session_id: "s1" } });
});

Deno.test("認証：トークンなし・無効なトークンは null（401にする）", async () => {
  assertEquals(
    await verifiedUser(fakeAdmin({ data: { user: { id: "u1" } }, error: null }), withAuth()),
    null,
  );
  assertEquals(
    await verifiedUser(
      fakeAdmin({ data: { user: null }, error: { message: "invalid" } }),
      withAuth(`Bearer ${jwt({})}`),
    ),
    null,
  );
  assertEquals(
    await verifiedUser(
      fakeAdmin({ data: { user: null }, error: null }),
      withAuth(`Bearer ${jwt({})}`),
    ),
    null,
  );
});

Deno.test("認証：Authへ問い合わせられない障害は、nullにせず、例外のまま投げる（401と取り違えない）", async () => {
  await assertRejects(() => verifiedUser(fakeAdmin("throw"), withAuth(`Bearer ${jwt({})}`)));
});

Deno.test("guarded：想定外の例外は、どの機能でも同じ500。内部の詳細・秘密は返さず、ログにも名前だけ", async () => {
  const original = console.error;
  const logs: string[] = [];
  console.error = (...args: unknown[]) => logs.push(args.map(String).join(" "));
  try {
    const handler = guarded(() => Promise.reject(new Error("db password hunter2 leaked")));
    const res = await handler(new Request("http://localhost/x"));
    assertEquals(res.status, 500);
    const text = await res.text();
    assertEquals(JSON.parse(text).error.code, "INTERNAL_ERROR");
    assert(!text.includes("hunter2"), "応答に秘密が出ている");
    assert(!logs.join("\n").includes("hunter2"), "ログに秘密が出ている");
    assert(logs.join("\n").includes("Error"), "例外の種類が残っていない");
    assertEquals(res.headers.get("Access-Control-Allow-Origin"), "*"); // ブラウザーでも読める
  } finally {
    console.error = original;
  }
});

Deno.test("guarded：正常な応答は、そのまま通す", async () => {
  const ok = errorResponse(404, "NOT_FOUND", "対象が見つかりません。");
  const res = await guarded(() => Promise.resolve(ok))(new Request("http://localhost/x"));
  assertEquals(res.status, 404);
});
