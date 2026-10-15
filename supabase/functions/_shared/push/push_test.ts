import { assert, assertEquals } from "@std/assert";
import { createFcmSender, parseServiceAccount, type ServiceAccount } from "./fcm.ts";
import { pushDispatchHandler } from "./handlers.ts";
import { pushMessage } from "./messages.ts";
import type { PushDeps, PushJob, PushOutcome } from "./types.ts";

const SECRET = "dispatch-secret-for-test";

const job = (over: Partial<PushJob> = {}): PushJob => ({
  deliveryId: "d-1",
  notificationId: "n-1",
  notificationType: "comment",
  platform: "ios",
  deviceToken: "device-token-secret-value",
  ...over,
});

function makeDeps(opts: {
  jobs?: PushJob[];
  result?: { outcome: PushOutcome; errorCode?: string };
  sendThrows?: boolean;
  finishThrows?: boolean;
  configured?: boolean;
  secret?: string | undefined;
} = {}) {
  const calls = { claim: 0, finish: [] as unknown[][], sent: [] as PushJob[] };
  const deps: PushDeps = {
    dispatchSecret: "secret" in opts ? opts.secret : SECRET,
    senderConfigured: opts.configured ?? true,
    db: {
      claim: () => {
        calls.claim++;
        return Promise.resolve(opts.jobs ?? [job()]);
      },
      finish: (...a) => {
        if (opts.finishThrows) return Promise.reject(new Error("db down"));
        calls.finish.push(a);
        return Promise.resolve();
      },
    },
    sender: {
      send: (j) => {
        calls.sent.push(j);
        if (opts.sendThrows) return Promise.reject(new Error("boom device-token-secret-value"));
        return Promise.resolve(opts.result ?? { outcome: "sent" });
      },
    },
  };
  return { deps, calls };
}

const req = (method = "POST", secret: string | null = SECRET) =>
  new Request("http://localhost/push-dispatch", {
    method,
    headers: secret === null ? {} : { "x-job-secret": secret },
  });

Deno.test("配信：秘密がない・違う・未設定のときは 404。キューに触れない", async () => {
  for (
    const [deps, r] of [
      [makeDeps().deps, req("POST", null)],
      [makeDeps().deps, req("POST", "wrong-secret")],
      [makeDeps({ secret: undefined }).deps, req("POST", SECRET)],
      [makeDeps({ secret: "" }).deps, req("POST", "")],
    ] as const
  ) {
    const f = makeDeps();
    const res = await pushDispatchHandler({ ...deps, db: f.deps.db })(r);
    assertEquals(res.status, 404);
    assertEquals((await res.json()).error.code, "NOT_FOUND");
    assertEquals(f.calls.claim, 0);
  }
});

Deno.test("配信：秘密が正しくても POST 以外は 405。FCMが未設定なら 503 で、キューを取り出さない", async () => {
  const f = makeDeps();
  assertEquals((await pushDispatchHandler(f.deps)(req("GET"))).status, 405);
  const g = makeDeps({ configured: false });
  assertEquals((await pushDispatchHandler(g.deps)(req())).status, 503);
  assertEquals(g.calls.claim, 0);
});

Deno.test("配信：取り出した分を送り、結果を記録する", async () => {
  const f = makeDeps({ jobs: [job(), job({ deliveryId: "d-2" })] });
  const res = await pushDispatchHandler(f.deps)(req());
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {
    claimed: 2,
    sent: 2,
    retry: 0,
    invalid_token: 0,
    record_failed: 0,
  });
  assertEquals(f.calls.finish.map((c) => c[0]), ["d-1", "d-2"]);
});

Deno.test("配信：無効な端末・一時的な失敗は、結果に応じて記録する", async () => {
  const bad = makeDeps({ result: { outcome: "invalid_token" } });
  assertEquals((await (await pushDispatchHandler(bad.deps)(req())).json()).invalid_token, 1);
  assertEquals(bad.calls.finish[0], ["d-1", "invalid_token", undefined]);

  const retry = makeDeps({ result: { outcome: "retry", errorCode: "FCM_503" } });
  assertEquals((await (await pushDispatchHandler(retry.deps)(req())).json()).retry, 1);
  assertEquals(retry.calls.finish[0], ["d-1", "retry", "FCM_503"]);
});

Deno.test("配信：送信で想定外の例外が出ても止まらず、再試行として記録する。内容はレスポンスに出さない", async () => {
  const f = makeDeps({ jobs: [job(), job({ deliveryId: "d-2" })], sendThrows: true });
  const res = await pushDispatchHandler(f.deps)(req());
  const text = await res.text();
  assertEquals(res.status, 200);
  assert(!text.includes("device-token-secret-value"));
  assertEquals(f.calls.finish.map((c) => [c[0], c[1], c[2]]), [
    ["d-1", "retry", "SEND_EXCEPTION"],
    ["d-2", "retry", "SEND_EXCEPTION"],
  ]);
});

Deno.test("配信：結果の記録に失敗しても 200。失敗数を返す（ロックが切れれば再び取り出される）", async () => {
  const f = makeDeps({ finishThrows: true });
  const body = await (await pushDispatchHandler(f.deps)(req())).json();
  assertEquals(body.record_failed, 1);
  assertEquals(body.sent, 0);
});

Deno.test("文面：本文・ニックネーム・件数を含まない定型文だけ", () => {
  for (const t of ["comment", "reply", "reaction_digest", "moderation", "unknown"]) {
    const m = pushMessage(t);
    assertEquals(m.title, "お知らせ");
    assert(m.body.length > 0 && m.body.length < 30, t);
    assert(!/[0-9０-９]/.test(m.body), `${t}: 数字（件数）を含む`);
  }
  assertEquals(pushMessage("comment").body, "あなたの投稿にコメントが届きました");
});

// --- FCM ---

async function makeAccount(): Promise<{ account: ServiceAccount; publicKey: CryptoKey }> {
  const keys = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keys.privateKey));
  let s = "";
  for (const b of der) s += String.fromCharCode(b);
  const pem = `-----BEGIN PRIVATE KEY-----\n${
    btoa(s).replace(/(.{64})/g, "$1\n")
  }\n-----END PRIVATE KEY-----\n`;
  return {
    account: {
      project_id: "proj-1",
      client_email: "svc@proj-1.iam.gserviceaccount.com",
      private_key: pem,
    },
    publicKey: keys.publicKey,
  };
}

function fakeFetch(fcmStatus: number) {
  const calls: { url: string; init?: RequestInit }[] = [];
  const fn: typeof fetch = (input, init) => {
    const url = String(input);
    calls.push({ url, init });
    if (url.includes("oauth2.googleapis.com")) {
      return Promise.resolve(
        new Response(JSON.stringify({ access_token: "access-1", expires_in: 3600 }), {
          status: 200,
        }),
      );
    }
    return Promise.resolve(
      new Response(fcmStatus === 200 ? "{}" : '{"error":{}}', { status: fcmStatus }),
    );
  };
  return { fn, calls };
}

Deno.test("FCM：サービスアカウントの設定は、形が正しいものだけ受け付ける", () => {
  assertEquals(parseServiceAccount(undefined), null);
  assertEquals(parseServiceAccount("not json"), null);
  assertEquals(parseServiceAccount('{"project_id":"p"}'), null);
  assert(parseServiceAccount('{"project_id":"p","client_email":"e","private_key":"k"}'));
});

Deno.test("FCM：署名つきJWTでトークンを取り、本文を含まない定型文で送る。トークンは使い回す", async () => {
  const { account, publicKey } = await makeAccount();
  const f = fakeFetch(200);
  const sender = createFcmSender(account, f.fn, () => 1_800_000_000_000);

  assertEquals((await sender.send(job())).outcome, "sent");
  assertEquals((await sender.send(job({ notificationType: "reply" }))).outcome, "sent");
  assertEquals(
    f.calls.filter((c) => c.url.includes("oauth2")).length,
    1,
    "アクセストークンは使い回す",
  );

  // JWTの署名・内容
  const tokenCall = f.calls.find((c) => c.url.includes("oauth2"))!;
  const assertion = new URLSearchParams(String(tokenCall.init!.body)).get("assertion")!;
  const [h, c, sig] = assertion.split(".");
  const dec = (s: string) =>
    Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (x) => x.charCodeAt(0));
  const claims = JSON.parse(new TextDecoder().decode(dec(c)));
  assertEquals(claims.iss, account.client_email);
  assertEquals(claims.scope, "https://www.googleapis.com/auth/firebase.messaging");
  assert(
    await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      publicKey,
      dec(sig),
      new TextEncoder().encode(`${h}.${c}`),
    ),
    "JWTの署名が検証できない",
  );

  // 送信内容
  const send = f.calls.find((x) => x.url.includes("fcm.googleapis.com"))!;
  assertEquals(send.url, "https://fcm.googleapis.com/v1/projects/proj-1/messages:send");
  const msg = JSON.parse(String(send.init!.body)).message;
  assertEquals(msg.token, "device-token-secret-value");
  assertEquals(msg.notification, { title: "お知らせ", body: "あなたの投稿にコメントが届きました" });
  assertEquals(msg.data, { type: "comment", notification_id: "n-1" });
  assertEquals((send.init!.headers as Record<string, string>).Authorization, "Bearer access-1");
});

/** FCM v1 のエラー応答の形。 */
function fcmError(status: number, httpStatus: string, errorCode?: string, message = "error") {
  return JSON.stringify({
    error: {
      code: status,
      message,
      status: httpStatus,
      details: errorCode
        ? [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode }]
        : [],
    },
  });
}

function fetchReturning(status: number, body: string) {
  const fn: typeof fetch = (input) =>
    String(input).includes("oauth2")
      ? Promise.resolve(
        new Response(JSON.stringify({ access_token: "access-1", expires_in: 3600 }), {
          status: 200,
        }),
      )
      : Promise.resolve(new Response(body, { status }));
  return fn;
}

Deno.test("FCM：端末が無効と確定できるときだけ invalid_token（UNREGISTERED、トークン不正の INVALID_ARGUMENT）", async () => {
  const { account } = await makeAccount();
  const invalid: [number, string][] = [
    [404, fcmError(404, "NOT_FOUND", "UNREGISTERED", "Requested entity was not found.")],
    [
      400,
      fcmError(
        400,
        "INVALID_ARGUMENT",
        undefined,
        "The registration token is not a valid FCM registration token",
      ),
    ],
  ];
  for (const [status, body] of invalid) {
    const sender = createFcmSender(account, fetchReturning(status, body), () => 1_800_000_000_000);
    assertEquals(await sender.send(job()), { outcome: "invalid_token" }, body);
  }
});

Deno.test("FCM：設定誤り・送信の不備・認証・混雑・障害では、端末を消さずに再試行する", async () => {
  const { account } = await makeAccount();
  const retry: [number, string, string][] = [
    // プロジェクトIDの誤りなどで、UNREGISTERED なしの 404 が返る
    [404, fcmError(404, "NOT_FOUND", undefined, "Requested entity was not found."), "FCM_404"],
    // 送信パラメータの不備（トークンとは無関係な INVALID_ARGUMENT）
    [
      400,
      fcmError(400, "INVALID_ARGUMENT", undefined, "Invalid JSON payload received."),
      "FCM_INVALID_ARGUMENT",
    ],
    // 応答が読めない
    [400, "<html>bad gateway</html>", "FCM_400"],
    [401, fcmError(401, "UNAUTHENTICATED", "THIRD_PARTY_AUTH_ERROR"), "FCM_AUTH"],
    [403, fcmError(403, "PERMISSION_DENIED", "SENDER_ID_MISMATCH"), "FCM_AUTH"],
    [429, fcmError(429, "RESOURCE_EXHAUSTED", "QUOTA_EXCEEDED"), "FCM_429"],
    [503, fcmError(503, "UNAVAILABLE", "UNAVAILABLE"), "FCM_503"],
    [500, fcmError(500, "INTERNAL"), "FCM_500"],
  ];
  for (const [status, body, code] of retry) {
    const sender = createFcmSender(account, fetchReturning(status, body), () => 1_800_000_000_000);
    assertEquals(
      await sender.send(job()),
      { outcome: "retry", errorCode: code },
      `${status} ${body}`,
    );
  }
});

Deno.test("FCM：送れたときは sent", async () => {
  const { account } = await makeAccount();
  const sender = createFcmSender(account, fetchReturning(200, "{}"), () => 1_800_000_000_000);
  assertEquals(await sender.send(job()), { outcome: "sent" });
});

Deno.test("FCM：ネットワーク失敗・トークン交換の失敗は再試行。エラーに端末トークンを含めない", async () => {
  const { account } = await makeAccount();
  const down: typeof fetch = (input) =>
    String(input).includes("oauth2")
      ? Promise.resolve(new Response("{}", { status: 200 }).clone())
      : Promise.reject(new Error("network device-token-secret-value"));
  const r1 = await createFcmSender(
    account,
    (i, n) =>
      String(i).includes("oauth2")
        ? Promise.resolve(new Response(JSON.stringify({ access_token: "a" }), { status: 200 }))
        : down(i, n),
  ).send(job());
  assertEquals(r1, { outcome: "retry", errorCode: "FCM_NETWORK" });

  const noAuth = createFcmSender(
    account,
    () => Promise.resolve(new Response("{}", { status: 500 })),
  );
  assertEquals(await noAuth.send(job()), { outcome: "retry", errorCode: "FCM_AUTH" });
});
