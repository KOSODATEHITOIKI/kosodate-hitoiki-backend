import { assert, assertEquals } from "@std/assert";
import {
  isModerationActionsPath,
  isModerationSettingsPath,
  moderationHandler,
  reportsHandler,
} from "./handlers.ts";
import {
  type AuthContext,
  type ModerationAction,
  type ReportsDeps,
  ReportsRuleError,
} from "./types.ts";

const USER = "00000000-0000-0000-0000-0000000000a2";
const ADMIN = "00000000-0000-0000-0000-0000000000a5";
const POST = "00000000-0000-0000-0000-0000000000b1";

interface Calls {
  reports: unknown[];
  moderation: unknown[];
  adminChecks: string[];
  settings: { adminId: string; key: string; value: unknown }[];
}

function makeFake(options: {
  auth?: AuthContext | null;
  registeredAdmin?: boolean;
  rule?: string;
  duplicate?: boolean;
  unexpected?: boolean;
} = {}): { deps: ReportsDeps; calls: Calls } {
  const calls: Calls = { reports: [], moderation: [], adminChecks: [], settings: [] };
  const maybeFail = () => {
    if (options.rule) throw new ReportsRuleError(options.rule);
    if (options.unexpected) throw new Error("boom with secret 本文");
  };
  const deps: ReportsDeps = {
    authenticate: () =>
      Promise.resolve(
        options.auth === undefined ? { userId: USER, aal: "aal1" } : options.auth,
      ),
    db: {
      createReport: (a) => {
        maybeFail();
        calls.reports.push(a);
        return Promise.resolve({ id: "r-1", duplicate: options.duplicate ?? false });
      },
      isRegisteredAdmin: (userId) => {
        calls.adminChecks.push(userId);
        return Promise.resolve(options.registeredAdmin ?? false);
      },
      getSettings: () => Promise.resolve({ new_signup_halted: false }),
      setSetting: (adminId, key, value) => {
        maybeFail();
        calls.settings.push({ adminId, key, value });
        return Promise.resolve();
      },
      applyModeration: (a) => {
        maybeFail();
        calls.moderation.push(a);
        return Promise.resolve({
          id: "m-1",
          action: a.action as ModerationAction,
          restriction_stage: a.action === "suspend" ? 1 : null,
        });
      },
    },
  };
  return { deps, calls };
}

function req(method: string, path: string, body?: unknown): Request {
  return new Request(`http://localhost${path}`, {
    method,
    headers: { "Content-Type": "application/json", Authorization: "Bearer token" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

const validReport = { target_type: "post", target_id: POST, reason: "harassment" };
const validAction = { target_type: "post", target_id: POST, action: "unhide" };

async function errorBody(res: Response) {
  return (await res.json()).error as { code: string; message: string; details?: unknown };
}

// --- 通報 ---

Deno.test("通報：未ログインは 401", async () => {
  const f = makeFake({ auth: null });
  assertEquals((await reportsHandler(f.deps)(req("POST", "/reports", validReport))).status, 401);
  assertEquals(f.calls.reports.length, 0);
});

Deno.test("通報：作成は 201。重複（既存の通報）は 200 で同じ形", async () => {
  const f = makeFake();
  const created = await reportsHandler(f.deps)(
    req("POST", "/reports", { ...validReport, detail: "  補足  " }),
  );
  assertEquals(created.status, 201);
  assertEquals(await created.json(), { id: "r-1", duplicate: false });
  assertEquals(f.calls.reports, [{
    reporterId: USER,
    targetType: "post",
    targetId: POST,
    reason: "harassment",
    detail: "補足",
  }]);

  const dup = makeFake({ duplicate: true });
  const res = await reportsHandler(dup.deps)(req("POST", "/reports", validReport));
  assertEquals(res.status, 200);
  assertEquals((await res.json()).duplicate, true);
});

Deno.test("通報：理由は6種。不正な理由・対象・IDは 422 でDBに触れない", async () => {
  for (const reason of ["harassment", "personal_info", "spam", "copyright", "danger", "other"]) {
    const f = makeFake();
    assertEquals(
      (await reportsHandler(f.deps)(req("POST", "/reports", { ...validReport, reason }))).status,
      201,
      reason,
    );
  }
  for (
    const body of [
      { ...validReport, reason: "invalid" },
      { ...validReport, reason: undefined },
      { ...validReport, target_type: "user" },
      { ...validReport, target_id: "not-a-uuid" },
      { ...validReport, detail: "あ".repeat(201) },
      { ...validReport, detail: 5 },
    ]
  ) {
    const f = makeFake();
    const res = await reportsHandler(f.deps)(req("POST", "/reports", body));
    assertEquals(res.status, 422, JSON.stringify(body).slice(0, 50));
    assertEquals(f.calls.reports.length, 0);
  }
});

Deno.test("通報：自分の対象・利用停止・プロフィール未登録は 403、存在しない・見えない対象は 404", async () => {
  for (
    const [rule, status, reason] of [
      ["FORBIDDEN", 403, "not_allowed"],
      ["RESTRICTED", 403, "restricted"],
      ["PROFILE_REQUIRED", 403, "profile_required"],
    ] as const
  ) {
    const f = makeFake({ rule });
    const res = await reportsHandler(f.deps)(req("POST", "/reports", validReport));
    assertEquals(res.status, status);
    assertEquals(((await errorBody(res)).details as { reason: string }).reason, reason);
  }
  const g = makeFake({ rule: "NOT_FOUND" });
  assertEquals((await reportsHandler(g.deps)(req("POST", "/reports", validReport))).status, 404);
});

Deno.test("通報：想定外のエラーは 500。内部の文言・本文を含めない", async () => {
  const f = makeFake({ unexpected: true });
  const res = await reportsHandler(f.deps)(req("POST", "/reports", validReport));
  assertEquals(res.status, 500);
  const text = JSON.stringify(await res.json());
  assert(!text.includes("secret") && !text.includes("本文"));
});

Deno.test("通報：メソッド違いは 405、プリフライトは 204", async () => {
  const f = makeFake();
  assertEquals((await reportsHandler(f.deps)(req("GET", "/reports"))).status, 405);
  assertEquals(
    (await reportsHandler(f.deps)(new Request("http://localhost/reports", { method: "OPTIONS" })))
      .status,
    204,
  );
});

// --- 運営の対処：運営者判定（404 と 403 の使い分け） ---

Deno.test("運営：パスの対応づけ", () => {
  assert(isModerationActionsPath("/moderation/actions"));
  assert(isModerationActionsPath("/functions/v1/moderation/actions"));
  assert(!isModerationActionsPath("/moderation"));
  assert(!isModerationActionsPath("/moderation/other"));
});

Deno.test("運営：未ログインは 401", async () => {
  const f = makeFake({ auth: null });
  assertEquals(
    (await moderationHandler(f.deps)(req("POST", "/moderation/actions", validAction))).status,
    401,
  );
});

Deno.test("運営：運営者として登録されていない利用者には、機能の存在を明かさない（404）。DBに触れない", async () => {
  const f = makeFake({ auth: { userId: USER, aal: "aal2" }, registeredAdmin: false });
  const res = await moderationHandler(f.deps)(req("POST", "/moderation/actions", validAction));
  assertEquals(res.status, 404);
  assertEquals((await errorBody(res)).code, "NOT_FOUND");
  assertEquals(f.calls.moderation.length, 0);
});

Deno.test("運営：二段階認証前（aal1）の運営者は 403（mfa_required）。対処は実行されない", async () => {
  for (const aal of ["aal1", "", "AAL2", "aal3"]) {
    const f = makeFake({ auth: { userId: ADMIN, aal }, registeredAdmin: true });
    const res = await moderationHandler(f.deps)(req("POST", "/moderation/actions", validAction));
    assertEquals(res.status, 403, aal);
    assertEquals(((await errorBody(res)).details as { reason: string }).reason, "mfa_required");
    assertEquals(f.calls.moderation.length, 0);
  }
});

Deno.test("運営：二段階認証済み（aal2）の運営者だけが対処できる", async () => {
  const f = makeFake({ auth: { userId: ADMIN, aal: "aal2" }, registeredAdmin: true });
  const res = await moderationHandler(f.deps)(
    req("POST", "/moderation/actions", { ...validAction, reason: "  誤検知のため  " }),
  );
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { id: "m-1", action: "unhide", restriction_stage: null });
  assertEquals(f.calls.moderation, [{
    adminId: ADMIN,
    targetType: "post",
    targetId: POST,
    action: "unhide",
    reason: "誤検知のため",
  }]);
});

Deno.test("運営：運営者のIDはトークンから取り、リクエスト本文の admin_id は使わない", async () => {
  const f = makeFake({ auth: { userId: ADMIN, aal: "aal2" }, registeredAdmin: true });
  await moderationHandler(f.deps)(
    req("POST", "/moderation/actions", { ...validAction, admin_id: USER }),
  );
  assertEquals((f.calls.moderation[0] as { adminId: string }).adminId, ADMIN);
  assertEquals(f.calls.adminChecks, [ADMIN]);
});

Deno.test("運営：利用停止は段階を返し、入力の不備は 422、DBの拒否は対応するコード", async () => {
  const auth = { userId: ADMIN, aal: "aal2" };
  const f = makeFake({ auth, registeredAdmin: true });
  const suspend = await moderationHandler(f.deps)(
    req("POST", "/moderation/actions", {
      target_type: "user",
      target_id: USER,
      action: "suspend",
      reason: "悪質なため",
    }),
  );
  assertEquals((await suspend.json()).restriction_stage, 1);

  for (
    const body of [
      { ...validAction, action: "invalid" },
      { ...validAction, target_type: "other" },
      { ...validAction, target_id: "x" },
      { ...validAction, reason: "あ".repeat(501) },
    ]
  ) {
    const g = makeFake({ auth, registeredAdmin: true });
    assertEquals(
      (await moderationHandler(g.deps)(req("POST", "/moderation/actions", body))).status,
      422,
    );
    assertEquals(g.calls.moderation.length, 0);
  }

  for (
    const [rule, status] of [["CONFLICT", 409], ["NOT_FOUND", 404], ["FORBIDDEN", 403], [
      "VALIDATION_FAILED",
      422,
    ]] as const
  ) {
    const g = makeFake({ auth, registeredAdmin: true, rule });
    assertEquals(
      (await moderationHandler(g.deps)(req("POST", "/moderation/actions", validAction))).status,
      status,
      rule,
    );
  }
});

Deno.test("運営：パス違い・メソッド違い", async () => {
  const f = makeFake({ auth: { userId: ADMIN, aal: "aal2" }, registeredAdmin: true });
  assertEquals((await moderationHandler(f.deps)(req("POST", "/moderation/other", {}))).status, 404);
  assertEquals((await moderationHandler(f.deps)(req("GET", "/moderation/actions"))).status, 405);
});

Deno.test("運営設定：パスの対応づけ", () => {
  assertEquals(isModerationSettingsPath("/moderation/settings"), true);
  assertEquals(isModerationSettingsPath("/functions/v1/moderation/settings/"), true);
  assertEquals(isModerationSettingsPath("/moderation/settings/x"), false);
});

Deno.test("運営設定：未ログインは 401、運営者でなければ 404、二段階認証前は 403。どれも設定に触れない", async () => {
  const body = { key: "new_signup_halted", value: true };
  const anon = makeFake({ auth: null });
  assertEquals(
    (await moderationHandler(anon.deps)(req("PUT", "/moderation/settings", body))).status,
    401,
  );

  const nonAdmin = makeFake({ auth: { userId: USER, aal: "aal2" }, registeredAdmin: false });
  assertEquals(
    (await moderationHandler(nonAdmin.deps)(req("PUT", "/moderation/settings", body))).status,
    404,
  );
  assertEquals(
    (await moderationHandler(nonAdmin.deps)(req("GET", "/moderation/settings"))).status,
    404,
  );

  const aal1 = makeFake({ auth: { userId: ADMIN, aal: "aal1" }, registeredAdmin: true });
  const res = await moderationHandler(aal1.deps)(req("PUT", "/moderation/settings", body));
  assertEquals(res.status, 403);
  assertEquals((await errorBody(res)).details, { reason: "mfa_required" });
  assertEquals(
    (await moderationHandler(aal1.deps)(req("GET", "/moderation/settings"))).status,
    403,
  );

  for (const f of [anon, nonAdmin, aal1]) assertEquals(f.calls.settings.length, 0);
});

Deno.test("運営設定：二段階認証済みの運営者だけが読み書きできる。運営者のIDはトークンから取る", async () => {
  const f = makeFake({ auth: { userId: ADMIN, aal: "aal2" }, registeredAdmin: true });
  const got = await moderationHandler(f.deps)(req("GET", "/moderation/settings"));
  assertEquals(got.status, 200);
  assertEquals((await got.json()).settings, { new_signup_halted: false });

  const put = await moderationHandler(f.deps)(
    req("PUT", "/moderation/settings", { key: "new_signup_halted", value: true, admin_id: USER }),
  );
  assertEquals(put.status, 200);
  assertEquals(f.calls.settings, [{ adminId: ADMIN, key: "new_signup_halted", value: true }]);
});

Deno.test("運営設定：未知のキー・キーや値の欠落は 422。DBの検証エラーも 422", async () => {
  const auth = { userId: ADMIN, aal: "aal2" };
  for (const body of [{ key: "other", value: 1 }, { value: true }, { key: "new_signup_halted" }]) {
    const f = makeFake({ auth, registeredAdmin: true });
    assertEquals(
      (await moderationHandler(f.deps)(req("PUT", "/moderation/settings", body))).status,
      422,
    );
    assertEquals(f.calls.settings.length, 0);
  }
  const f = makeFake({ auth, registeredAdmin: true, rule: "VALIDATION_FAILED" });
  assertEquals(
    (await moderationHandler(f.deps)(
      req("PUT", "/moderation/settings", { key: "new_user_limit", value: { enabled: "x" } }),
    )).status,
    422,
  );
  assertEquals(
    (await moderationHandler(makeFake({ auth, registeredAdmin: true }).deps)(
      req("POST", "/moderation/settings", {}),
    )).status,
    405,
  );
});
