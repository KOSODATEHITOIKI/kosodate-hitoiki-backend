// 運営者の二段階認証（TOTP）を、あなたのPCから登録・確認する小さなスクリプト。
// 運営の画面（フロント）ができるまでの代わり。docs/運営の二段階認証.md の手順4。
//
//   npx deno run --allow-net --allow-env scripts/ops/operator-mfa.ts
//
// 流れ：①ログイン（メールとパスワード）→ ②運営の画面のAPIを呼ぶ（二段階認証の前：403が正しい）→
//       ③認証アプリに登録して検証（6桁のコード）→ ④もう一度APIを呼ぶ（二段階認証の後：200が正しい）。
//
// 入力するもの：プロジェクトのURL、公開キー（publishable／anon。秘密ではない）、運営者のメールとパスワード。
// パスワードは画面に表示されず、このPCの外へは、Supabaseへのログイン以外に送られない。
// secret／service_role のキーは、絶対に使わない（このスクリプトは、拒否する）。
// 外部のライブラリに依存しない（パスワードを扱うため）。Supabase Auth のHTTP APIを、標準の fetch で直接呼ぶ。

// --- 入力 ---
function readLine(label: string, fallback?: string): string {
  const v = prompt(
    label + (fallback ? `（Enterで ${fallback}）` : ""),
    fallback,
  );
  return (v ?? fallback ?? "").trim();
}

/** 画面に表示せずに読む（パスワード用）。 */
async function readHidden(label: string): Promise<string> {
  const fromEnv = Deno.env.get("OPERATOR_PASSWORD");
  if (fromEnv) return fromEnv; // 自動テスト用
  await Deno.stdout.write(
    new TextEncoder().encode(label + "（入力は表示されません）: "),
  );
  Deno.stdin.setRaw(true);
  const bytes: number[] = [];
  const buf = new Uint8Array(1);
  try {
    while (true) {
      const n = await Deno.stdin.read(buf);
      if (n === null) break;
      const c = buf[0];
      if (c === 13 || c === 10) break; // Enter
      if (c === 3) Deno.exit(130); // Ctrl+C
      if (c === 127 || c === 8) bytes.pop(); // BackSpace
      else bytes.push(c);
    }
  } finally {
    Deno.stdin.setRaw(false);
    await Deno.stdout.write(new TextEncoder().encode("\n"));
  }
  return new TextDecoder().decode(new Uint8Array(bytes));
}

// --- TOTP（自動テスト用：秘密から6桁を計算する。本番では使わない） ---
function base32Decode(input: string): Uint8Array {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const ch of input.replace(/=+$/, "").replace(/\s/g, "").toUpperCase()) {
    value = (value << 5) | alphabet.indexOf(ch);
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return new Uint8Array(out);
}

async function totp(secret: string): Promise<string> {
  const buf = new ArrayBuffer(8);
  new DataView(buf).setBigUint64(0, BigInt(Math.floor(Date.now() / 1000 / 30)));
  const key = await crypto.subtle.importKey(
    "raw",
    base32Decode(secret) as BufferSource,
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const h = new Uint8Array(await crypto.subtle.sign("HMAC", key, buf));
  const o = h[h.length - 1] & 0x0f;
  const code = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) |
    h[o + 3];
  return String(code % 1_000_000).padStart(6, "0");
}

// --- 本体 ---
const url = (Deno.env.get("SUPABASE_URL") ??
  readLine("プロジェクトのURL（例：https://xxxx.supabase.co）")).replace(
    /\/$/,
    "",
  );
const key = Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ??
  readLine("公開キー（sb_publishable_… または anon）");
const email = Deno.env.get("OPERATOR_EMAIL") ??
  readLine("運営者のメールアドレス");
const password = await readHidden("パスワード");

// 特権キーを誤って使わないための確認
if (key.startsWith("sb_secret_")) {
  throw new Error(
    "secretキーは使えません。公開キー（publishable／anon）を使ってください。",
  );
}
const payload = key.split(".")[1];
if (payload) {
  try {
    const role =
      JSON.parse(atob(payload.replace(/-/g, "+").replace(/_/g, "/"))).role;
    if (role === "service_role") {
      throw new Error(
        "service_role のキーは使えません。公開キー（anon）を使ってください。",
      );
    }
  } catch (e) {
    if (e instanceof Error && e.message.includes("service_role")) throw e;
  }
}

const AUTH = `${url}/auth/v1`;

// deno-lint-ignore no-explicit-any
type Json = any;

async function authCall(
  path: string,
  init: RequestInit & { token?: string } = {},
): Promise<{ status: number; json: Json }> {
  const res = await fetch(`${AUTH}${path}`, {
    ...init,
    headers: {
      apikey: key,
      "Content-Type": "application/json",
      ...(init.token ? { Authorization: `Bearer ${init.token}` } : {}),
    },
  });
  let json: Json = null;
  try {
    json = await res.json();
  } catch {
    // 本文なし
  }
  return { status: res.status, json };
}

async function callSettings(token: string): Promise<number> {
  const res = await fetch(`${url}/functions/v1/moderation/settings`, {
    headers: { Authorization: `Bearer ${token}`, apikey: key },
  });
  await res.body?.cancel();
  return res.status;
}

console.log("\n== 1. ログイン ==");
const signIn = await authCall("/token?grant_type=password", {
  method: "POST",
  body: JSON.stringify({ email, password }),
});
if (signIn.status !== 200 || !signIn.json?.access_token) {
  console.error(
    "ログインできませんでした：メールアドレス・パスワードを確認してください。",
  );
  Deno.exit(1);
}
const aal1Token: string = signIn.json.access_token;
console.log("ログインできました。");

console.log("\n== 2. 二段階認証の前（aal1）に、運営の画面のAPIを呼ぶ ==");
const before = await callSettings(aal1Token);
const explain: Record<number, string> = {
  403: "運営者として登録されていて、二段階認証が必要な状態です（これが正しい）",
  404:
    "運営者として登録されていません（先に、SQL Editorで admin_users に登録してください）",
  200: "二段階認証なしで通ってしまいました（想定外：すぐに報告してください）",
  401: "認証されていません",
};
console.log(`HTTP ${before}：${explain[before] ?? "想定外の応答"}`);
if (before === 404) {
  console.log("→ 運営者の登録を済ませてから、もう一度実行してください。");
  Deno.exit(2);
}
if (before === 200) Deno.exit(3);

console.log("\n== 3. 認証アプリに登録して、検証する ==");
const me = await authCall("/user", { token: aal1Token });
const totpFactors: Json[] = (me.json?.factors ?? []).filter((f: Json) =>
  f.factor_type === "totp"
);
const verified = totpFactors.find((f: Json) => f.status === "verified");
let factorId: string;
let enrolledSecret = "";
if (verified) {
  factorId = verified.id;
  console.log(
    "すでに認証アプリが登録されています。登録済みの認証アプリのコードで検証します。",
  );
} else {
  // 検証されていない古い登録は、先に外す（再実行できるように）
  for (const f of totpFactors) {
    await authCall(`/factors/${f.id}`, { method: "DELETE", token: aal1Token });
  }
  const enroll = await authCall("/factors", {
    method: "POST",
    token: aal1Token,
    body: JSON.stringify({
      factor_type: "totp",
      friendly_name: "kosodate-operator",
    }),
  });
  if (enroll.status !== 200 || !enroll.json?.totp) {
    console.error(
      "認証アプリの登録を始められませんでした。Authentication → Multi-Factor で TOTP が有効か確認してください。",
    );
    Deno.exit(1);
  }
  factorId = enroll.json.id;
  enrolledSecret = enroll.json.totp.secret;
  console.log(
    "認証アプリ（Google Authenticator、Microsoft Authenticator など）で、次のどちらかで登録してください。",
  );
  console.log(
    `  ・「セットアップキーを入力」を選び、キー：  ${enrolledSecret}`,
  );
  console.log(
    `  ・または、このURIを読み込む（QR対応のアプリ）：\n    ${enroll.json.totp.uri}`,
  );
  console.log(
    "※ このキーは、あなたの二段階認証の秘密です。他の人に見せず、チャットにも貼らないでください。",
  );
}

// TOTP_AUTO=1 は自動テスト用（登録した秘密から6桁を計算する）。通常は使わない。
const code = Deno.env.get("TOTP_AUTO") === "1" && enrolledSecret
  ? await totp(enrolledSecret)
  : readLine("認証アプリに表示されている6桁のコード");
const challenge = await authCall(`/factors/${factorId}/challenge`, {
  method: "POST",
  token: aal1Token,
  body: "{}",
});
if (challenge.status !== 200 || !challenge.json?.id) {
  console.error("検証を始められませんでした。");
  Deno.exit(1);
}
const verify = await authCall(`/factors/${factorId}/verify`, {
  method: "POST",
  token: aal1Token,
  body: JSON.stringify({ challenge_id: challenge.json.id, code }),
});
if (verify.status !== 200 || !verify.json?.access_token) {
  console.error(
    "コードが違います。認証アプリの最新の6桁を入れて、もう一度実行してください。",
  );
  Deno.exit(1);
}
console.log("二段階認証の検証に成功しました。");

console.log("\n== 4. 二段階認証の後（aal2）に、同じAPIを呼ぶ ==");
const after = await callSettings(verify.json.access_token);
console.log(
  `HTTP ${after}：${
    after === 200
      ? "運営の画面のAPIが使えます（これが正しい）"
      : "想定外の応答（報告してください）"
  }`,
);
Deno.exit(after === 200 ? 0 : 4);
