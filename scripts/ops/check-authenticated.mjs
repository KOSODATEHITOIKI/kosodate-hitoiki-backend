#!/usr/bin/env node
/**
 * ログイン済みの視点で、実際のAPIに問い合わせて、公開範囲と権限が想定どおりかを確かめる。
 * check-exposure.sh（未ログイン）の続き。コードやDBテストではなく、**動いている環境（local・dev・prod）に対して**確かめる。
 * 設定の差分（鍵・ダッシュボードの設定ミス・デプロイの漏れ）による、意図しない公開を見つけるため。
 *
 * 投稿・コメントは作らない（送信前チェック・外部APIを通さない）。確かめるのは、
 *   ① 他人・運営専用・内部専用のデータが、ログインしても読めないこと
 *   ② 直接の書き込み（送信前チェックを迂回できる経路）が、拒否されること
 *   ③ 内部用の関数・運営の入口・退会が、ログインしただけでは使えないこと
 *   ④ 偽造・改ざんしたトークンが通らないこと
 *   ⑤ （2人目があれば）他人のプロフィール・ブロックの事実が見えないこと
 *
 * 使い方（パスワードは、自分のPCの環境変数にだけ入れる。チャットや履歴に残さない）：
 *   API_URL=https://<ref>.supabase.co ANON_KEY=<公開キー> \
 *   EMAIL_A=... PASSWORD_A=... [EMAIL_B=... PASSWORD_B=...] node scripts/ops/check-authenticated.mjs
 *
 * 前提：EMAIL_A・EMAIL_B は、テスト用の新しいアカウント（運営者ではない。投稿・通報・ブロックなどのデータがない）。
 * 特権キー（service_role・secret）は、絶対に使わない。出力には、メールアドレス・トークン・本文を出さない。
 * いずれか1つでも想定外なら、失敗（終了コード1）にする。
 */

const API_URL = (process.env.API_URL ?? "").replace(/\/+$/, "");
const ANON_KEY = process.env.ANON_KEY ?? "";
const A = { email: process.env.EMAIL_A ?? "", password: process.env.PASSWORD_A ?? "" };
const B = { email: process.env.EMAIL_B ?? "", password: process.env.PASSWORD_B ?? "" };

if (!API_URL || !ANON_KEY || !A.email || !A.password) {
  console.error("API_URL・ANON_KEY（公開キー）・EMAIL_A・PASSWORD_A を指定してください");
  process.exit(2);
}

/** 特権キーを渡されたら、検査が無意味になる（何でも読める）ので、使わせない。 */
function looksPrivileged(key) {
  if (key.startsWith("sb_secret_")) return true;
  try {
    const payload = JSON.parse(Buffer.from(key.split(".")[1] ?? "", "base64url").toString("utf8"));
    return payload.role === "service_role";
  } catch {
    return false;
  }
}
if (looksPrivileged(ANON_KEY)) {
  console.error("ANON_KEY が特権キーです。公開キー（publishable／anon）を使ってください。");
  process.exit(2);
}

let failed = 0;
const ok = (msg) => console.log(`ok   - ${msg}`);
const ng = (msg) => {
  console.log(`FAIL - ${msg}`);
  failed = 1;
};
const info = (msg) => console.log(`info - ${msg}`);

async function call(method, path, { token, body, headers = {}, raw = false } = {}) {
  const res = await fetch(`${API_URL}${path}`, {
    method,
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${token ?? ANON_KEY}`,
      ...(body !== undefined && !raw ? { "Content-Type": "application/json" } : {}),
      ...headers,
    },
    body: body === undefined ? undefined : raw ? body : JSON.stringify(body),
    signal: AbortSignal.timeout(30000),
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch { /* 本文がJSONでないものもある */ }
  return { status: res.status, json, text };
}

/**
 * ログインする。失敗したときは、原因を調べられるよう、HTTPの状態とAuthのエラーコードだけを返す
 * （invalid_credentials・email_not_confirmed など。メールアドレス・パスワード・応答の本文は出さない）。
 */
async function signIn(who) {
  const r = await call("POST", "/auth/v1/token?grant_type=password", {
    body: { email: who.email, password: who.password },
  });
  const token = r.json?.access_token;
  const userId = r.json?.user?.id;
  if (r.status !== 200 || !token || !userId) {
    const code = typeof r.json?.error_code === "string" ? r.json.error_code : "unknown";
    return { failure: `HTTP ${r.status}、${code}` };
  }
  return { token, userId };
}

/** ログインできなかった理由の、案内（コードごと）。 */
function loginHint(failure) {
  if (failure.includes("invalid_credentials")) return "パスワードの打ち間違い、またはメールアドレスが違う、アカウントが存在しない可能性";
  if (failure.includes("email_not_confirmed")) return "メールの確認が済んでいない（作成時に Auto Confirm User を入れ忘れた）可能性";
  if (failure.includes("user_banned")) return "アカウントが停止されている";
  if (failure.includes("over_request_rate_limit") || failure.includes("429")) return "ログインの試行が多すぎる。しばらく待つ";
  return "Authの設定・接続先（API_URL）・公開キー（ANON_KEY）を確認";
}

const DENIED = [401, 403, 404];
const isDenied = (r) => DENIED.includes(r.status);
const isEmpty = (r) => r.status === 200 && Array.isArray(r.json) && r.json.length === 0;

console.log("== 1. ログイン ==");
const aLogin = await signIn(A);
const a = aLogin.failure ? null : aLogin;
if (!a) {
  ng(`アカウントAでログインできない（${aLogin.failure}）。${loginHint(aLogin.failure)}`);
  console.log("\nログイン済みの確認：続けられません");
  process.exit(1);
}
ok("アカウントAでログインできる");
let b = null;
if (B.email && B.password) {
  const bLogin = await signIn(B);
  if (!bLogin.failure) {
    b = bLogin;
    ok("アカウントBでログインできる");
  } else {
    ng(`アカウントBでログインできない（${bLogin.failure}）。${loginHint(bLogin.failure)}`);
  }
} else {
  info("EMAIL_B・PASSWORD_B がないので、2人の間の確認（7）は飛ばします");
}

console.log("== 2. 他人・運営専用・内部専用のデータが、ログインしても読めないこと ==");
{
  // 内部専用：ログイン済みにも権限がない（拒否）。運営専用・本人専用：権限はあるが、行がない（0件）。
  const mustBeDeniedOrEmpty = [
    "reports", "moderation_actions", "account_restrictions", "admin_users", "admin_report_queue",
    "app_settings", "app_settings_history", "nickname_reservations", "terms_acceptances",
    "push_deliveries", "write_events", "request_budget", "pending_storage_deletions",
    "deletion_ledger", "idempotency_keys", "profile_icons",
  ];
  let bad = 0;
  for (const t of mustBeDeniedOrEmpty) {
    const r = await call("GET", `/rest/v1/${t}?select=*&limit=5`, { token: a.token });
    if (!(isDenied(r) || isEmpty(r))) {
      ng(`${t}：ログイン済みに、行が見える・想定外の応答（HTTP ${r.status}${Array.isArray(r.json) ? `、${r.json.length}行` : ""}）`);
      bad++;
    }
  }
  if (!bad) ok("運営専用・内部専用・他人のデータは、拒否または0件（アカウントAの視点）");

  // 自分の行しか返らない表（新しいアカウントなら0件）
  const own = ["blocks", "saved_posts", "hidden_items", "muted_topics", "muted_words", "notifications", "push_devices", "reactions"];
  bad = 0;
  for (const t of own) {
    const r = await call("GET", `/rest/v1/${t}?select=*&limit=5`, { token: a.token });
    if (r.status !== 200 || !Array.isArray(r.json)) {
      ng(`${t}：想定外の応答（HTTP ${r.status}）`);
      bad++;
    } else if (r.json.some((row) => Object.values(row).some((v) => v === b?.userId))) {
      ng(`${t}：他人（アカウントB）の行が見える`);
      bad++;
    }
  }
  if (!bad) ok("本人用の表に、他人の行が混ざらない");

  // profiles は本人（と運営者）だけ。1行以下で、あればAの行
  const p = await call("GET", "/rest/v1/profiles?select=id,bio,child_age_range", { token: a.token });
  if (p.status === 200 && Array.isArray(p.json) && p.json.length <= 1 && p.json.every((r) => r.id === a.userId)) {
    ok("profiles は、自分の行だけ（プロフィール本文・年齢帯は本人だけが読める）");
  } else {
    ng(`profiles：自分以外の行が見える・想定外の応答（HTTP ${p.status}）`);
  }

  // 運営用の判定は、運営者でないので false
  const adm = await call("POST", "/rest/v1/rpc/is_admin", { token: a.token, body: {} });
  if (adm.status === 200 && adm.json === false) ok("is_admin：運営者ではない（false）");
  else ng(`is_admin：想定外の応答（HTTP ${adm.status}）。テスト用アカウントが運営者になっていないか確認`);

  // 公開ビューに、投稿者の利用者ID以外の機密列がないこと（列の確認）
  const posts = await call("GET", "/rest/v1/public_posts?select=author_id&limit=1", { token: a.token });
  if (isDenied(posts) || posts.status === 400) ok("public_posts に author_id 列はない（投稿者の利用者IDを出さない）");
  else ng(`public_posts から author_id が読める（HTTP ${posts.status}）`);
  const pp = await call("GET", "/rest/v1/public_profiles?select=bio&limit=1", { token: a.token });
  if (isDenied(pp) || pp.status === 400) ok("public_profiles に bio 列はない");
  else ng(`public_profiles から bio が読める（HTTP ${pp.status}）`);
}

console.log("== 3. 直接の書き込み（送信前チェック・確認を迂回できる経路）が拒否されること ==");
{
  const fakeId = "00000000-0000-4000-8000-000000000001";
  const writes = [
    ["posts", { author_id: a.userId, post_type: "guchi", body: "直接書き込み", reaction_mode: "quiet_support" }],
    ["comments", { post_id: fakeId, author_id: a.userId, body: "直接書き込み" }],
    ["reactions", { post_id: fakeId, user_id: a.userId, reaction_type_id: 1 }],
    ["reports", { reporter_id: a.userId, target_type: "post", target_id: fakeId, reason: "other" }],
    ["profiles", { id: a.userId, nickname: "ちょくせつ" }],
    ["push_devices", { user_id: a.userId, platform: "ios", device_token: "direct-write-token-0001" }],
    ["app_settings", { key: "new_signup_halted", value: true }],
    ["moderation_actions", { action: "delete", target_type: "post", target_id: fakeId }],
    ["account_restrictions", { user_id: a.userId }],
    ["admin_users", { user_id: a.userId }],
    ["notifications", { user_id: a.userId, notification_type: "moderation" }],
    ["reaction_types", { label: "ちょくせつ" }],
    ["topics", { label: "ちょくせつ" }],
    ["profile_icons", { code: "direct_write" }],
  ];
  let bad = 0;
  for (const [t, row] of writes) {
    const r = await call("POST", `/rest/v1/${t}`, { token: a.token, body: row, headers: { Prefer: "return=minimal" } });
    if (r.status >= 200 && r.status < 300) {
      ng(`${t} へ直接書き込めた（HTTP ${r.status}）`);
      bad++;
    }
  }
  if (!bad) ok("送信前チェックの対象・運営用・内部用のテーブルへの直接の書き込みは、すべて拒否された");

  // 既存の行の更新・削除も拒否（自分の行でも）
  let bad2 = 0;
  for (const [t, filter] of [["profiles", `id=eq.${a.userId}`], ["posts", `author_id=eq.${a.userId}`], ["comments", `author_id=eq.${a.userId}`]]) {
    const upd = await call("PATCH", `/rest/v1/${t}?${filter}`, { token: a.token, body: { body: "改ざん", nickname: "かいざん" }, headers: { Prefer: "return=representation" } });
    const del = await call("DELETE", `/rest/v1/${t}?${filter}`, { token: a.token, headers: { Prefer: "return=representation" } });
    for (const [kind, r] of [["更新", upd], ["削除", del]]) {
      const changed = r.status >= 200 && r.status < 300 && Array.isArray(r.json) && r.json.length > 0;
      if (changed) {
        ng(`${t} の自分の行を、直接${kind}できた`);
        bad2++;
      }
    }
  }
  if (!bad2) ok("自分の行でも、プロフィール・投稿・コメントを直接更新・削除できない");
}

console.log("== 4. 内部用の関数・運営の入口・退会が、ログインしただけでは使えないこと ==");
{
  const internalRpc = [
    "create_post", "create_comment", "create_report", "set_reaction", "remove_reaction", "withdraw_account",
    "replay_deletion_ledger", "import_deletion_ledger", "purge_expired_records", "claim_push_deliveries",
    "finish_push_delivery", "set_app_setting", "preflight_write", "moderation_apply", "create_profile",
    "session_started_at", "generate_reaction_digests", "claim_storage_deletions", "replay_idempotent_response",
    "remember_support_notice", "job_secret_valid", "invoke_internal_job", "delete_comment", "setup_internal_jobs",
  ];
  let bad = 0;
  for (const fn of internalRpc) {
    const r = await call("POST", `/rest/v1/rpc/${fn}`, { token: a.token, body: {} });
    if (!isDenied(r)) {
      ng(`関数 ${fn} が、ログイン済みに応答した（HTTP ${r.status}）`);
      bad++;
    }
  }
  if (!bad) ok("内部用の関数は、ログイン済みにも拒否される");

  const fnCall = async (method, path, body) => await call(method, `/functions/v1/${path}`, { token: a.token, body });
  // 運営の入口は、運営者でないと存在も明かさない（404）
  for (const [method, path, body] of [["GET", "moderation/settings"], ["PUT", "moderation/settings", { key: "new_signup_halted", value: true }], ["POST", "moderation/actions", { target_type: "post", target_id: "00000000-0000-4000-8000-000000000001", action: "unhide" }]]) {
    const r = await fnCall(method, path, body);
    if (r.status === 404) ok(`${path}（${method}）：運営者でなければ、存在を明かさない（404）`);
    else ng(`${path}（${method}）：想定外（HTTP ${r.status}、期待 404）`);
  }
  // 内部用の起動口は、秘密なしでは404
  for (const path of ["push-dispatch", "storage-cleanup"]) {
    const r = await fnCall("POST", path, {});
    if (r.status === 404) ok(`${path}：秘密なしでは、存在を明かさない（404）`);
    else ng(`${path}：想定外（HTTP ${r.status}、期待 404）`);
  }
  // 退会：確認（confirm）なしは422。実際には退会させない（confirm: true は、絶対に送らない）
  const del = await fnCall("POST", "account-delete", {});
  if (del.status === 422) ok("account-delete：確認なしは422（退会しない）");
  else ng(`account-delete：想定外（HTTP ${del.status}、期待 422）`);
  // 投稿作成：不正な本文は、送信前チェックの前に422（外部APIを呼ばない）
  const post = await fnCall("POST", "posts", { post_type: "guchi", body: "" });
  if (post.status === 422) ok("posts：空の本文は422（送信前チェックの前に止まる）");
  else ng(`posts：想定外（HTTP ${post.status}、期待 422）`);
  // 呼べる関数は、想定した範囲だけ
  const cnt = await call("POST", "/rest/v1/rpc/get_post_reaction_count", { token: a.token, body: { p_post_id: "00000000-0000-4000-8000-000000000001" } });
  if (cnt.status === 200 && Number(cnt.json) === 0) ok("get_post_reaction_count：他人の投稿の件数は0（存在を明かさない）");
  else ng(`get_post_reaction_count：想定外（HTTP ${cnt.status}）`);
}

console.log("== 5. 偽造・改ざんしたトークンが通らないこと ==");
{
  const [h, p, s] = a.token.split(".");
  const tamper = (obj) => `${h}.${Buffer.from(JSON.stringify(obj)).toString("base64url")}.${s}`;
  const payload = JSON.parse(Buffer.from(p, "base64url").toString("utf8"));
  const tokens = {
    "署名を壊したトークン": `${h}.${p}.${s.slice(0, -4)}AAAA`,
    "運営者・特権へ書き換えたトークン": tamper({ ...payload, role: "service_role" }),
    "別の利用者へ書き換えたトークン": tamper({ ...payload, sub: "00000000-0000-4000-8000-000000000002" }),
  };
  for (const [label, token] of Object.entries(tokens)) {
    const rest = await call("GET", "/rest/v1/profiles?select=id", { token });
    const fn = await call("POST", "/functions/v1/posts", { token, body: { post_type: "guchi", body: "x" } });
    const restOk = rest.status === 401 || rest.status === 403;
    const fnOk = fn.status === 401;
    if (restOk && fnOk) ok(`${label}：REST・Edge Functions とも拒否（401）`);
    else ng(`${label}：通ってしまった・想定外（REST ${rest.status}、Functions ${fn.status}）`);
  }
  const none = await call("POST", "/functions/v1/posts", { body: { post_type: "guchi", body: "x" } });
  if (none.status === 401) ok("ログインなし（公開キーだけ）で、投稿の作成は401");
  else ng(`ログインなしで投稿の作成：想定外（HTTP ${none.status}）`);
}

console.log("== 6. Storage（アカウント画像）：直接アップロード・一覧ができないこと ==");
{
  const up = await call("POST", `/storage/v1/object/avatars/${a.userId}/direct.png`, {
    token: a.token,
    raw: true,
    body: Buffer.from([0x89, 0x50, 0x4e, 0x47]),
    headers: { "Content-Type": "image/png" },
  });
  if (up.status >= 200 && up.status < 300) ng(`avatars へ直接アップロードできた（HTTP ${up.status}）。確認とメタデータ除去を迂回できる`);
  else ok("avatars への直接アップロードは拒否された（Edge Functions 経由だけ）");
  const list = await call("POST", "/storage/v1/object/list/avatars", { token: a.token, body: { prefix: "", limit: 5 } });
  if (list.status === 200 && Array.isArray(list.json) && list.json.length > 0) ng("avatars の一覧が、ログイン済みに取れた");
  else ok("avatars の一覧は取れない（URLを知っている画像だけが見える）");
}

console.log("== 7. 2人の間：他人のプロフィール・ブロックの事実が見えないこと ==");
if (b) {
  const pa = await call("GET", `/rest/v1/profiles?select=id&id=eq.${a.userId}`, { token: b.token });
  if (isEmpty(pa) || isDenied(pa)) ok("BからAの profiles（本文・年齢帯）は見えない");
  else ng(`BからAの profiles が見える（HTTP ${pa.status}）`);

  // AがBをブロックする（本人のRLSで直接行う。確認のあと、必ず解除する）
  const ins = await call("POST", "/rest/v1/blocks", {
    token: a.token,
    body: { blocker_id: a.userId, blocked_id: b.userId },
    headers: { Prefer: "return=minimal" },
  });
  if (ins.status >= 200 && ins.status < 300) {
    try {
      const seenByB = await call("GET", "/rest/v1/blocks?select=*", { token: b.token });
      const myBlocksB = await call("GET", "/rest/v1/my_blocks?select=*", { token: b.token });
      if (isEmpty(seenByB) && isEmpty(myBlocksB)) ok("ブロックされたBからは、ブロックされている事実が見えない（blocks・my_blocks とも0件）");
      else ng("ブロックされたBから、ブロックの事実が見える");
      const mine = await call("GET", "/rest/v1/my_blocks?select=blocked_id,blocked_nickname,blocked_icon_key", { token: a.token });
      if (mine.status === 200 && Array.isArray(mine.json) && mine.json.length === 1 && mine.json[0].blocked_id === b.userId) {
        ok("ブロックしたAには、my_blocks で相手の表示名が見える");
      } else if (mine.status === 200 && Array.isArray(mine.json) && mine.json.length === 0) {
        info("my_blocks が0件（Bのプロフィールが未登録の可能性。プロフィール登録後に、もう一度確認してください）");
      } else {
        ng(`my_blocks：想定外の応答（HTTP ${mine.status}）`);
      }
    } finally {
      await call("DELETE", `/rest/v1/blocks?blocked_id=eq.${b.userId}`, { token: a.token });
    }
  } else {
    ng(`AがBをブロックできない（HTTP ${ins.status}）。本人用のRLSの確認が必要`);
  }
} else if (B.email && B.password) {
  info("（Bにログインできなかったので、2人の間の確認は、できていません。Bを直して、もう一度実行してください）");
} else {
  info("（2人目がないので飛ばしました）");
}

console.log();
if (failed) {
  console.log("ログイン済みの確認：想定外があります");
  process.exit(1);
}
console.log("ログイン済みの確認：すべて想定どおり");
