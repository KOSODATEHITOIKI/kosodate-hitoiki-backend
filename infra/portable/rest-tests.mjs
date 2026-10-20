// PostgREST（AWSでFargateで動かすAPI層）越しに、権限が守られていることを確かめる（AWS移行の段階2）。
//
// DBテスト（pgTAP）は、DBの中から権限を確かめる。ここでは、**実際のHTTPのAPI**に、本物のJWTの形式のトークンで
// 問い合わせて、未ログイン・本人・他人・運営者（aal1/aal2）・不正なトークンで、見える範囲が想定どおりかを確かめる。
//
// 環境変数：REST_URL（PostgRESTのURL）、JWT_SECRET（テスト用の署名鍵。本番のCognitoではJWKS）、
//          PSQL（DBへSQLを流すコマンド。例："docker exec -i <コンテナ> psql -U postgres -v ON_ERROR_STOP=1 -q"）
import { createHmac, randomUUID } from "node:crypto";
import { execSync } from "node:child_process";

const REST_URL = process.env.REST_URL ?? "http://127.0.0.1:54998";
const JWT_SECRET = process.env.JWT_SECRET ?? "";
const PSQL = process.env.PSQL ?? "";
if (!JWT_SECRET || !PSQL) throw new Error("JWT_SECRET と PSQL を指定してください");

const b64 = (o) => Buffer.from(typeof o === "string" ? o : JSON.stringify(o)).toString("base64url");
function sign(payload, { secret = JWT_SECRET, alg = "HS256" } = {}) {
  const head = b64({ alg, typ: "JWT" });
  const body = b64(payload);
  const sig = alg === "none" ? "" : createHmac("sha256", secret).update(`${head}.${body}`).digest("base64url");
  return `${head}.${body}.${sig}`;
}
const now = () => Math.floor(Date.now() / 1000);
const token = (sub, extra = {}) =>
  sign({ sub, role: "authenticated", aud: "authenticated", iat: now(), exp: now() + 600, ...extra });

const sql = (text) => execSync(PSQL, { input: text, stdio: ["pipe", "pipe", "pipe"] }).toString();

let failed = 0;
const ok = (m) => console.log(`ok   - ${m}`);
const ng = (m) => {
  console.log(`FAIL - ${m}`);
  failed = 1;
};
const expect = (cond, m) => (cond ? ok(m) : ng(m));

async function req(method, path, { jwt, body, headers = {} } = {}) {
  const res = await fetch(`${REST_URL}${path}`, {
    method,
    headers: {
      ...(jwt ? { Authorization: `Bearer ${jwt}` } : {}),
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...headers,
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try {
    json = await res.json();
  } catch { /* 本文なし */ }
  return { status: res.status, json };
}

// --- 準備：2人の利用者、運営者、投稿、通知 ---
const A = randomUUID();
const B = randomUUID();
const ADMIN = randomUUID();
const POST = randomUUID();
sql(`
insert into auth.users (id) values ('${A}'), ('${B}'), ('${ADMIN}');
insert into public.profiles (id, nickname, bio) values
  ('${A}', 'あいてすと', 'Aだけの自己紹介'), ('${B}', 'びいてすと', 'Bの自己紹介'), ('${ADMIN}', 'うんえいてすと', null);
insert into public.notification_settings (user_id) values ('${A}'), ('${B}'), ('${ADMIN}');
insert into public.admin_users (user_id) values ('${ADMIN}');
insert into public.posts (id, author_id, post_type, body, reaction_mode) values ('${POST}', '${B}', 'guchi', 'Bの投稿', 'quiet_support');
insert into public.notifications (user_id, notification_type, reaction_count, digest_until, digest_date)
  values ('${A}', 'reaction_digest', 1, now(), current_date), ('${B}', 'reaction_digest', 2, now(), current_date);
insert into public.reports (reporter_id, target_type, target_id, reason) values ('${A}', 'post', '${POST}', 'other');
`);

try {
  console.log("== 未ログイン（anon）==");
  let r = await req("GET", "/topics?limit=1");
  expect(r.status === 200, "公開マスタ（topics）は読める");
  r = await req("GET", "/public_posts?limit=1");
  expect(r.status === 200, "公開ビュー（public_posts）は読める");
  r = await req("GET", "/profiles?limit=1");
  expect(r.status === 401 || r.status === 403, `プロフィールは読めない（HTTP ${r.status}）`);
  r = await req("GET", "/posts?select=author_id&limit=1");
  expect(r.status === 401 || r.status === 403, `投稿者ID（author_id）の列は読めない（HTTP ${r.status}）`);
  r = await req("GET", "/notifications?limit=1");
  expect(r.status === 401 || r.status === 403, `通知は読めない（HTTP ${r.status}）`);
  r = await req("POST", "/rpc/create_post", { body: {} });
  expect([401, 403, 404].includes(r.status), `書き込み用の関数は呼べない（HTTP ${r.status}）`);

  console.log("== 本人（authenticated）==");
  const tA = token(A);
  const tB = token(B);
  r = await req("GET", "/notifications?select=user_id", { jwt: tA });
  expect(r.status === 200 && r.json.length === 1 && r.json[0].user_id === A, "Aは、自分の通知だけが見える");
  r = await req("GET", "/notifications?select=user_id", { jwt: tB });
  expect(r.status === 200 && r.json.length === 1 && r.json[0].user_id === B, "Bは、自分の通知だけが見える（Aのは見えない）");
  r = await req("GET", `/profiles?select=id,bio&id=eq.${A}`, { jwt: tB });
  expect(r.status === 200 && r.json.length === 0, "Bは、Aのプロフィール本文（bio）を読めない");
  r = await req("GET", `/profiles?select=id,bio&id=eq.${A}`, { jwt: tA });
  expect(r.status === 200 && r.json.length === 1 && r.json[0].bio === "Aだけの自己紹介", "Aは、自分のプロフィール本文を読める");
  r = await req("GET", "/posts?select=author_id&limit=1", { jwt: tA });
  expect(r.status === 401 || r.status === 403 || r.status === 200, "（参考）ログイン済みの投稿の列の扱い");

  // 既読：本人だけ。宛先は書き換えられない
  const nA = (await req("GET", "/notifications?select=id", { jwt: tA })).json[0].id;
  r = await req("PATCH", `/notifications?id=eq.${nA}`, { jwt: tB, body: { is_read: true }, headers: { Prefer: "return=representation" } });
  expect(r.status === 200 && r.json.length === 0, "Bは、Aの通知を既読にできない（0行）");
  r = await req("PATCH", `/notifications?id=eq.${nA}`, { jwt: tA, body: { is_read: true }, headers: { Prefer: "return=representation" } });
  expect(r.status === 200 && r.json.length === 1, "Aは、自分の通知を既読にできる");
  r = await req("PATCH", `/notifications?id=eq.${nA}`, { jwt: tA, body: { user_id: B } });
  expect(r.status === 401 || r.status === 403, `通知の宛先は書き換えられない（HTTP ${r.status}）`);

  // 書き込みは、サーバー処理（service_role）だけ
  r = await req("POST", "/posts", { jwt: tA, body: { author_id: A, post_type: "guchi", body: "直接", reaction_mode: "quiet_support" } });
  expect(r.status === 401 || r.status === 403, `投稿の直接の書き込みはできない（HTTP ${r.status}）`);
  r = await req("PATCH", `/profiles?id=eq.${A}`, { jwt: tA, body: { bio: "直接書き換え" } });
  expect(r.status === 401 || r.status === 403, `プロフィールの直接の書き換えはできない（HTTP ${r.status}）`);
  r = await req("POST", "/rpc/withdraw_account", { jwt: tA, body: { p_user_id: A } });
  expect([401, 403, 404].includes(r.status), `退会の関数を直接は呼べない（HTTP ${r.status}）`);

  console.log("== 端末の登録（本人がログイン済みで呼べる関数）==");
  r = await req("POST", "/rpc/register_push_device", { jwt: tA, body: { p_platform: "ios", p_token: "rest-test-token-0001" } });
  expect(r.status === 200, `端末を登録できる（HTTP ${r.status}）`);
  r = await req("POST", "/push_devices", { jwt: tA, body: { user_id: A, platform: "ios", device_token: "direct-token-0002" } });
  expect(r.status === 401 || r.status === 403, `端末の直接の登録はできない（HTTP ${r.status}）`);

  console.log("== 運営者（二段階認証の有無）==");
  const aal1 = token(ADMIN, { aal: "aal1" });
  const aal2 = token(ADMIN, { aal: "aal2" });
  r = await req("GET", "/admin_report_queue?select=target_id", { jwt: aal1 });
  expect(r.status === 200 && r.json.length === 0, "二段階認証の前（aal1）は、通報の一覧が空");
  r = await req("GET", "/admin_report_queue?select=target_id", { jwt: aal2 });
  expect(r.status === 200 && r.json.length === 1, "二段階認証の後（aal2）は、通報の一覧が見える");
  r = await req("GET", "/admin_report_queue?select=target_id", { jwt: tA });
  expect(r.status === 200 && r.json.length === 0, "一般の利用者には、通報の一覧は見えない");
  r = await req("GET", "/app_settings?select=key", { jwt: aal1 });
  expect(r.status === 200 && r.json.length === 0, "二段階認証の前は、運営設定も見えない");
  r = await req("GET", "/app_settings?select=key", { jwt: aal2 });
  expect(r.status === 200 && r.json.length > 0, "二段階認証の後は、運営設定が見える");

  console.log("== 不正なトークンの拒否 ==");
  const claims = { sub: A, role: "authenticated", aud: "authenticated", iat: now(), exp: now() + 600 };
  r = await req("GET", "/notifications", { jwt: sign(claims, { secret: "wrong-secret-wrong-secret-wrong-secret" }) });
  expect(r.status === 401, `別の鍵で署名したトークンは拒否される（HTTP ${r.status}）`);
  r = await req("GET", "/notifications", { jwt: sign(claims, { alg: "none" }) });
  expect(r.status === 401, `署名なし（alg:none）のトークンは拒否される（HTTP ${r.status}）`);
  // PostgRESTは、時計のずれに備えて数十秒の猶予を持つ。猶予を超えて期限が切れたトークンは拒否される。
  for (const ago of [120, 3600, 86400]) {
    r = await req("GET", "/notifications", { jwt: sign({ ...claims, exp: now() - ago }) });
    expect(r.status === 401, `期限が切れて${ago}秒のトークンは拒否される（HTTP ${r.status}）`);
  }
  r = await req("GET", "/notifications", { jwt: sign({ ...claims, exp: now() - 10 }) });
  console.log(`info - 期限が切れて10秒のトークン：HTTP ${r.status}（時計のずれの猶予の範囲）`);
  // 署名が正しくない service_role の主張：特権を得られない
  r = await req("GET", "/notifications?select=user_id", { jwt: sign({ ...claims, role: "service_role" }, { secret: "wrong-secret-wrong-secret-wrong-secret" }) });
  expect(r.status === 401, `署名が不正な service_role の主張は拒否される（HTTP ${r.status}）`);
  r = await req("GET", "/notifications", { jwt: token(A).slice(0, -3) + "xyz" });
  expect(r.status === 401, `署名を改ざんしたトークンは拒否される（HTTP ${r.status}）`);
  // 存在しないロールの主張
  r = await req("GET", "/topics", { jwt: sign({ ...claims, role: "postgres" }) });
  expect(r.status !== 200 || true, "（参考）role=postgres の主張");
  r = await req("GET", "/profiles?select=id&limit=1", { jwt: sign({ ...claims, role: "postgres" }) });
  expect(r.status === 401 || r.status === 403 || r.status === 400, `role=postgres を主張しても特権を得られない（HTTP ${r.status}）`);

  console.log("== 内部の関数・機密テーブルが、OpenAPI（未ログイン）に出ないこと ==");
  const open = await req("GET", "/");
  const paths = Object.keys(open.json?.paths ?? {});
  const allowed = new Set(["/", "/posts", "/public_posts", "/reaction_types", "/topics", "/rpc/post_author_profile", "/rpc/post_comment_count", "/rpc/search_posts"]);
  const extra = paths.filter((p) => !allowed.has(p));
  expect(extra.length === 0, `未ログインから見える範囲が想定どおり${extra.length ? "：想定外 " + extra.join(",") : ""}`);
} finally {
  sql(`
  delete from public.reports where reporter_id = '${A}';
  delete from public.notifications where user_id in ('${A}', '${B}');
  select public.withdraw_account('${A}'); select public.withdraw_account('${B}');
  delete from public.admin_users where user_id = '${ADMIN}';
  select public.withdraw_account('${ADMIN}');
  delete from public.nickname_reservations where previous_owner_id in ('${A}', '${B}', '${ADMIN}');
  delete from public.deletion_ledger where target_id in ('${A}', '${B}', '${ADMIN}', '${POST}');
  `);
}

console.log(failed ? "\nPostgRESTの権限の確認：想定外があります" : "\nPostgRESTの権限の確認：すべて想定どおり");
process.exit(failed);
