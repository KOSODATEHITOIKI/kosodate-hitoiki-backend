import { assertEquals } from "@std/assert";
import { checkText } from "./check.ts";
import { EVAL_CASES } from "./eval_cases.ts";
import type { ModerationScores } from "./types.ts";

/**
 * OpenAI Moderation APIの実測スコア（2026-10-15、omni-moderation-latest）。
 * 評価例（eval_cases.ts）の本文に対して、判定に使うカテゴリのスコアを記録したもの。
 * 外部APIを呼ばずに、閾値（policy.ts）と表現リスト（support_phrases.ts）を変えたときの判定の変化を
 * 確認する回帰テスト。閾値を調整したら、まずこのテストで、愚痴を止めていないことを確かめる。
 *
 * 並び：harassment, harassment/threatening, hate, hate/threatening,
 *       self-harm, self-harm/intent, self-harm/instructions, violence
 * ローカル判定（禁止語・個人情報）で止まる例（a2〜a4・p1〜p5）は、APIを呼ばないため含めない。
 */
const KEYS = [
  "harassment",
  "harassment/threatening",
  "hate",
  "hate/threatening",
  "self-harm",
  "self-harm/intent",
  "self-harm/instructions",
  "violence",
] as const;

const MEASURED: Record<string, readonly number[]> = {
  g1: [0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00],
  g2: [0.01, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00],
  g3: [0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00],
  g4: [0.01, 0.00, 0.00, 0.00, 0.04, 0.00, 0.00, 0.18],
  a1: [0.80, 0.53, 0.01, 0.00, 0.46, 0.66, 0.18, 0.43],
  h1: [0.00, 0.00, 0.00, 0.00, 0.29, 0.52, 0.00, 0.01],
  h2: [0.01, 0.00, 0.00, 0.00, 0.16, 0.12, 0.01, 0.07],
  h3: [0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.02],
  b1: [0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00],
  b2: [0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00],
  b3: [0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00],
  b4: [0.01, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00],
  g5: [0.00, 0.00, 0.00, 0.00, 0.52, 0.61, 0.00, 0.05],
  g6: [0.00, 0.00, 0.00, 0.00, 0.02, 0.01, 0.00, 0.00],
  g7: [0.01, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00],
  g8: [0.02, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00],
  g9: [0.11, 0.00, 0.01, 0.00, 0.00, 0.00, 0.00, 0.03],
  g10: [0.04, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.01],
  m1: [0.36, 0.15, 0.01, 0.00, 0.01, 0.01, 0.00, 0.52],
  m2: [0.31, 0.00, 0.01, 0.00, 0.00, 0.00, 0.00, 0.00],
  m3: [0.81, 0.00, 0.01, 0.00, 0.00, 0.00, 0.00, 0.00],
  a5: [0.64, 0.28, 0.01, 0.00, 0.12, 0.10, 0.01, 0.10],
  a6: [0.98, 0.00, 0.01, 0.00, 0.00, 0.00, 0.00, 0.00],
  a7: [0.74, 0.11, 0.57, 0.01, 0.00, 0.00, 0.00, 0.01],
  a8: [0.40, 0.46, 0.01, 0.00, 0.00, 0.00, 0.00, 0.68],
  h4: [0.01, 0.00, 0.00, 0.00, 0.06, 0.10, 0.00, 0.00],
  h5: [0.00, 0.00, 0.00, 0.00, 0.16, 0.13, 0.00, 0.00],
  h6: [0.02, 0.02, 0.00, 0.00, 0.04, 0.01, 0.00, 0.81],
  h7: [0.00, 0.00, 0.00, 0.00, 0.76, 0.81, 0.00, 0.02],
  h8: [0.01, 0.01, 0.00, 0.00, 0.00, 0.00, 0.00, 0.18],
};

function scoresOf(id: string): ModerationScores {
  return Object.fromEntries(KEYS.map((k, i) => [k, MEASURED[id][i]]));
}

/** 実測の判定から、期待（decision・案内）を決める。 */
const EXPECT: Record<string, { decision: "allow" | "confirm" | "reject"; support: boolean }> = {
  // 愚痴：止めない。「死にそう」の誇張（g5）は、案内を出してよい（止めない）
  g1: { decision: "allow", support: false },
  g2: { decision: "allow", support: false },
  g3: { decision: "allow", support: false },
  g4: { decision: "allow", support: false },
  g5: { decision: "allow", support: true },
  g6: { decision: "allow", support: false },
  g7: { decision: "allow", support: false },
  g8: { decision: "allow", support: false },
  g9: { decision: "allow", support: false },
  g10: { decision: "allow", support: false },
  // 境界：愚痴に近い強い言葉は、止めない（m1・m2）か、確認を出す（m3）
  m1: { decision: "allow", support: false },
  m2: { decision: "allow", support: false },
  m3: { decision: "confirm", support: false },
  b1: { decision: "allow", support: false },
  b2: { decision: "allow", support: false },
  b3: { decision: "allow", support: false },
  b4: { decision: "allow", support: false },
  // 攻撃：止める。a5は表現リスト（禁止語）で止まり、APIを呼ばない
  a1: { decision: "reject", support: true },
  a5: { decision: "reject", support: false },
  a6: { decision: "reject", support: false },
  a7: { decision: "reject", support: false },
  a8: { decision: "reject", support: true },
  // 危害示唆：止めず、案内する
  h1: { decision: "allow", support: true },
  h2: { decision: "allow", support: true },
  h3: { decision: "allow", support: true }, // APIは検知しない。表現リストで案内
  h4: { decision: "allow", support: true },
  h5: { decision: "allow", support: true },
  h6: { decision: "allow", support: true },
  h7: { decision: "allow", support: true },
  h8: { decision: "allow", support: true }, // APIは弱い（violence 0.18）。表現リストで案内
};

for (const c of EVAL_CASES) {
  const expected = EXPECT[c.id];
  if (!expected) continue; // ローカル判定で止まる例は、rules_test.ts で検証している
  Deno.test(`実測スコア ${c.id}（${c.category}）→ ${expected.decision}・案内${expected.support ? "あり" : "なし"}`, async () => {
    const calls: string[] = [];
    const result = await checkText(c.text, {
      moderate: (text) => {
        calls.push(text);
        return Promise.resolve(MEASURED[c.id] ? scoresOf(c.id) : {});
      },
    });
    assertEquals(result.decision, expected.decision);
    assertEquals(result.supportNotice, expected.support);
    if (c.id === "a5") assertEquals(calls.length, 0); // 禁止語で止まり、外部APIへ送らない
  });
}

Deno.test("実測スコアの回帰：愚痴（g）と境界（b）は、1件も止めない（rejectにしない）", async () => {
  for (const id of Object.keys(MEASURED).filter((k) => /^(g|b)\d+$/.test(k))) {
    const c = EVAL_CASES.find((e) => e.id === id)!;
    const result = await checkText(c.text, { moderate: () => Promise.resolve(scoresOf(id)) });
    assertEquals(result.decision, "allow", `${id} が止まった`);
  }
});

Deno.test("閾値の調整で、愚痴の最大スコアと攻撃の最小スコアの間に余裕があることを示す（記録）", () => {
  // 愚痴・境界の、拒否に関わるスコアの最大値
  const ids = Object.keys(MEASURED).filter((k) => /^(g|b)\d+$/.test(k));
  const maxThreat = Math.max(...ids.map((id) => MEASURED[id][1]));
  const maxHate = Math.max(...ids.map((id) => MEASURED[id][2]));
  // 現在の拒否の閾値（脅迫0.4、hate0.5）に対して、愚痴の最大は十分に低い
  assertEquals(maxThreat < 0.4, true);
  assertEquals(maxHate < 0.5, true);
});
