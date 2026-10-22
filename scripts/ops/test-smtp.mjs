#!/usr/bin/env node
/**
 * メール送信（SMTP）の設定を、Supabase を通さずに、直接確かめる。
 * 「Supabaseで『Error sending confirmation email』になる」ときに、原因が、
 *   ①接続（ホスト・ポート）②認証（ユーザー名・APIキー）③送信元ドメインの確認 ④宛先
 * のどこにあるかを切り分けるために使う。実際に、テストのメールを1通、送る。
 *
 * 使い方（APIキーは、自分のPCの環境変数にだけ入れる。チャットや履歴に残さない）：
 *   SMTP_PASSWORD=<APIキー> FROM=noreply@mail.example.com TO=自分のアドレス node scripts/ops/test-smtp.mjs
 *   （省略時：SMTP_HOST=smtp.resend.com SMTP_PORT=465 SMTP_USER=resend）
 *
 * 出力には、APIキー・認証情報を出さない。サーバーの応答の番号と、1行目の説明だけを出す。
 */
import tls from "node:tls";

const HOST = process.env.SMTP_HOST ?? "smtp.resend.com";
const PORT = Number(process.env.SMTP_PORT ?? 465);
const USER = process.env.SMTP_USER ?? "resend";
const PASSWORD = process.env.SMTP_PASSWORD ?? "";
const FROM = process.env.FROM ?? "";
const TO = process.env.TO ?? "";

if (!PASSWORD || !FROM || !TO) {
  console.error("SMTP_PASSWORD（APIキー）・FROM（送信元）・TO（宛先）を指定してください");
  process.exit(2);
}
if (PORT !== 465) {
  console.error("このスクリプトは、最初からTLSで接続するポート（465）だけに対応しています");
  process.exit(2);
}

let failed = false;
const say = (ok, msg) => console.log(`${ok ? "ok  " : "FAIL"} - ${msg}`);

const socket = tls.connect({ host: HOST, port: PORT, servername: HOST, timeout: 20000 });
socket.setEncoding("utf8");
let buffer = "";
const waiters = [];

socket.on("data", (chunk) => {
  buffer += chunk;
  // 複数行の応答は、「250-…」が続き、最後の行が「250 …」（番号のあとが空白）
  for (;;) {
    const lines = buffer.split("\r\n");
    const end = lines.findIndex((l, i) => i < lines.length - 1 && /^\d{3} /.test(l));
    if (end === -1) break;
    const reply = lines.slice(0, end + 1);
    buffer = lines.slice(end + 1).join("\r\n");
    const w = waiters.shift();
    if (w) w(reply);
  }
});
socket.on("timeout", () => fatal("接続がタイムアウトしました（ホスト・ポート・ネットワークを確認）"));
socket.on("error", (e) => fatal(`接続に失敗しました（${e.code ?? "unknown"}）`));

function fatal(msg) {
  say(false, msg);
  process.exit(1);
}

const next = () => new Promise((resolve) => waiters.push(resolve));
const code = (reply) => Number(reply[reply.length - 1].slice(0, 3));
/** サーバーの説明（1行目だけ。認証情報は含まれない）。 */
const text = (reply) => reply[reply.length - 1].slice(4, 120);

async function step(label, command, expect) {
  if (command !== null) socket.write(`${command}\r\n`);
  const reply = await next();
  const c = code(reply);
  const ok = expect.includes(c);
  say(ok, `${label}：${c} ${text(reply)}`);
  if (!ok) {
    failed = true;
    hint(label, c);
    socket.end();
    process.exit(1);
  }
  return reply;
}

function hint(label, c) {
  const hints = {
    "認証": "→ ユーザー名（resend）か、APIキーが違う・無効。Resendでキーを作り直して、もう一度試す",
    "送信元（MAIL FROM）": "→ 送信元のドメインが、Resendで確認済み（Verified）ではない、またはAPIキーの対象ドメインと違う",
    "宛先（RCPT TO）": "→ 宛先が受け付けられない。ドメイン未確認のときは、登録したアドレス宛てにしか送れないことがある",
    "本文の送信": "→ 送信元ドメイン・内容が、受け付けられなかった。Resendの画面のログで、理由を確認する",
  };
  if (hints[label]) console.log(hints[label]);
  if (c === 454 || c === 421) console.log("→ サーバー側の一時的な問題・上限。しばらく待つ");
}

await step("接続", null, [220]);
await step("あいさつ（EHLO）", "EHLO test.local", [250]);
const auth = Buffer.from(`\u0000${USER}\u0000${PASSWORD}`).toString("base64");
// 認証情報は、出力に含めない（step は、サーバーの応答だけを表示する）
await step("認証", `AUTH PLAIN ${auth}`, [235]);
await step("送信元（MAIL FROM）", `MAIL FROM:<${FROM}>`, [250]);
await step("宛先（RCPT TO）", `RCPT TO:<${TO}>`, [250, 251]);
await step("データの開始", "DATA", [354]);
const date = new Date().toUTCString();
const body = [
  `From: ひと息 <${FROM}>`,
  `To: <${TO}>`,
  `Subject: =?UTF-8?B?${Buffer.from("【ひと息】メール送信のテスト").toString("base64")}?=`,
  `Date: ${date}`,
  "MIME-Version: 1.0",
  "Content-Type: text/plain; charset=UTF-8",
  "Content-Transfer-Encoding: base64",
  "",
  Buffer.from("これは、メール送信の設定を確かめるためのテストです。心当たりがなければ、破棄してください。").toString("base64"),
  ".",
].join("\r\n");
await step("本文の送信", body, [250]);
socket.write("QUIT\r\n");
socket.end();

console.log(failed ? "\nメール送信のテスト：失敗" : "\nメール送信のテスト：成功（宛先の受信箱・迷惑メールフォルダーを確認してください）");
process.exit(failed ? 1 : 0);
