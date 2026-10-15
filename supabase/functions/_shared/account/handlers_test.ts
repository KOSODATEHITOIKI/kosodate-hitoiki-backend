import { assert, assertEquals } from "@std/assert";
import { accountDeleteHandler, RECENT_LOGIN_MS } from "./handlers.ts";
import { type AccountDeps, AccountRuleError, toAccountError } from "./types.ts";

const NOW = Date.parse("2026-10-15T12:00:00Z");
const iso = (agoMs: number) => new Date(NOW - agoMs).toISOString();

function makeFake(opts: {
  auth?: { userId: string; sessionStartedAt: string | null } | null;
  operator?: boolean;
  storageFails?: boolean;
  withdrawRule?: string;
  withdrawFails?: boolean;
  status?: "deleted" | "already_deleted";
} = {}) {
  const calls: string[] = [];
  const deps: AccountDeps = {
    now: () => NOW,
    authenticate: () =>
      Promise.resolve(
        opts.auth === undefined ? { userId: "u-1", sessionStartedAt: iso(60_000) } : opts.auth,
      ),
    db: {
      isOperator: () => {
        calls.push("isOperator");
        return Promise.resolve(opts.operator ?? false);
      },
      withdraw: () => {
        calls.push("withdraw");
        if (opts.withdrawRule) return Promise.reject(new AccountRuleError(opts.withdrawRule));
        if (opts.withdrawFails) return Promise.reject(new Error("db down secret"));
        return Promise.resolve(opts.status ?? "deleted");
      },
    },
    storage: {
      removeAllFor: () => {
        calls.push("removeImages");
        return opts.storageFails ? Promise.reject(new Error("storage down")) : Promise.resolve();
      },
    },
  };
  return { deps, calls };
}

const req = (body: unknown = { confirm: true }, method = "POST") =>
  new Request("http://localhost/account-delete", {
    method,
    headers: { "Content-Type": "application/json", Authorization: "Bearer t" },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });

const code = async (res: Response) => (await res.json()).error;

Deno.test("退会：未ログインは 401。何も削除しない", async () => {
  const f = makeFake({ auth: null });
  assertEquals((await accountDeleteHandler(f.deps)(req())).status, 401);
  assertEquals(f.calls, []);
});

Deno.test("退会：確認（confirm: true）がなければ 422。何も削除しない", async () => {
  for (const body of [{}, { confirm: "true" }, { confirm: false }, "x"]) {
    const f = makeFake();
    assertEquals((await accountDeleteHandler(f.deps)(req(body))).status, 422);
    assertEquals(f.calls, []);
  }
});

Deno.test("退会：本人確認は、このセッションが5分以内に作られていること。古い・不明なら 403（reauth_required）", async () => {
  for (const last of [iso(RECENT_LOGIN_MS + 1000), iso(24 * 3600 * 1000), null, "not-a-date"]) {
    const f = makeFake({ auth: { userId: "u-1", sessionStartedAt: last } });
    const res = await accountDeleteHandler(f.deps)(req());
    assertEquals(res.status, 403);
    assertEquals((await code(res)).details, { reason: "reauth_required" });
    assertEquals(f.calls, [], "本人確認の前に何も削除してはいけない");
  }
  const edge = makeFake({ auth: { userId: "u-1", sessionStartedAt: iso(RECENT_LOGIN_MS - 1000) } });
  assertEquals((await accountDeleteHandler(edge.deps)(req())).status, 200);
});

Deno.test("退会：運営者として登録されていると 409。画像もDBも削除しない", async () => {
  const f = makeFake({ operator: true });
  const res = await accountDeleteHandler(f.deps)(req());
  assertEquals(res.status, 409);
  assertEquals((await code(res)).details, { reason: "operator_registered" });
  assertEquals(f.calls, ["isOperator"]);
});

Deno.test("退会：DB関数が運営者の登録を理由に拒否した場合も 409", async () => {
  const f = makeFake({ withdrawRule: "OPERATOR_REGISTERED" });
  assertEquals((await accountDeleteHandler(f.deps)(req())).status, 409);
});

Deno.test("退会：成功は 200。画像を先に削除してから、DBを削除する", async () => {
  const f = makeFake();
  const res = await accountDeleteHandler(f.deps)(req());
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { status: "deleted" });
  assertEquals(f.calls, ["isOperator", "removeImages", "withdraw"]);
});

Deno.test("退会：再実行（削除済み）も 200", async () => {
  const f = makeFake({ status: "already_deleted" });
  assertEquals(await (await accountDeleteHandler(f.deps)(req())).json(), {
    status: "already_deleted",
  });
});

Deno.test("退会：画像の削除に失敗したら 500 で、DBは削除しない（再実行できる）", async () => {
  const f = makeFake({ storageFails: true });
  const res = await accountDeleteHandler(f.deps)(req());
  assertEquals(res.status, 500);
  assertEquals(f.calls, ["isOperator", "removeImages"]);
});

Deno.test("退会：DBの失敗は 500。内部の文言を返さない", async () => {
  const f = makeFake({ withdrawFails: true });
  const res = await accountDeleteHandler(f.deps)(req());
  assertEquals(res.status, 500);
  assert(!JSON.stringify(await res.json()).includes("secret"));
});

Deno.test("退会：POST 以外は 405。プリフライトは 204", async () => {
  const f = makeFake();
  assertEquals((await accountDeleteHandler(f.deps)(req(undefined, "GET"))).status, 405);
  assertEquals(
    (await accountDeleteHandler(f.deps)(new Request("http://localhost/x", { method: "OPTIONS" })))
      .status,
    204,
  );
});

Deno.test("DBエラーの変換：運営者の登録だけをコードにし、それ以外は内部情報を捨てる", () => {
  const rule = toAccountError({ code: "P0001", message: "OPERATOR_REGISTERED" });
  assert(rule instanceof AccountRuleError);
  const other = toAccountError({ code: "P0001", message: "select * from secrets" });
  assert(!(other instanceof AccountRuleError));
  assertEquals(other.message, "database error");
});
