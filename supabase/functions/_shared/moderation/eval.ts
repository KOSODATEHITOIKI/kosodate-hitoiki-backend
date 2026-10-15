/**
 * 評価例（eval_cases.ts）を実際のOpenAI Moderation APIに通し、判定結果とスコアを表示する。
 * 閾値（policy.ts）を調整するときの確認用で、CIでは実行しない（APIキーと課金が必要なため）。
 *
 *   PowerShell:  $env:OPENAI_API_KEY = Read-Host "OpenAIのキー"; npm.cmd run functions:eval
 *
 * 出力にはケースID・判定・スコアだけを出し、本文・APIキーは出さない（結果は docs/送信前チェック評価.md に記録する）。
 * スコアは、判定に使うカテゴリだけを小数2桁で出す。ローカル判定（禁止語・個人情報）で止まる例は、
 * 外部APIを呼ばないため、スコアは「-」になる。
 */
import { checkText } from "./check.ts";
import { EVAL_CASES } from "./eval_cases.ts";
import { callModeration } from "./openai.ts";
import type { ModerationScores } from "./types.ts";

const apiKey = Deno.env.get("OPENAI_API_KEY");
if (!apiKey) {
  console.error("OPENAI_API_KEY が未設定です");
  Deno.exit(1);
}

/** 判定に使うカテゴリ（policy.ts）と、表で使う短い名前。 */
const SHOWN: readonly [string, string][] = [
  ["harassment", "harass"],
  ["harassment/threatening", "harass/thr"],
  ["hate", "hate"],
  ["hate/threatening", "hate/thr"],
  ["self-harm", "self"],
  ["self-harm/intent", "self/int"],
  ["self-harm/instructions", "self/ins"],
  ["violence", "viol"],
];

let last: ModerationScores | null = null;
const deps = {
  moderate: async (text: string) => {
    last = await callModeration(text, { apiKey });
    return last;
  },
};

console.log(
  `| id | 分類 | 期待 | 判定 | 相談先案内 | 理由 | ${SHOWN.map(([, n]) => n).join(" | ")} |`,
);
console.log(`|---|---|---|---|---|---|${SHOWN.map(() => "---").join("|")}|`);
for (const c of EVAL_CASES) {
  last = null;
  const r = await checkText(c.text, deps);
  const scores = last as ModerationScores | null;
  const cells = SHOWN.map(([key]) => scores ? (scores[key] ?? 0).toFixed(2) : "-");
  console.log(
    `| ${c.id} | ${c.category} | ${c.expected} | ${r.decision} | ${
      r.supportNotice ? "あり" : "なし"
    } | ${r.reasons.join(", ") || "-"} | ${cells.join(" | ")} |`,
  );
}
