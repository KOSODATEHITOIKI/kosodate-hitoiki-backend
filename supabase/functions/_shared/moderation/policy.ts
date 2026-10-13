import type { ModerationScores, Reason } from "./types.ts";

/**
 * Moderationスコアの閾値（設計案・未調整の初期値）。
 * 日本語の愚痴と攻撃の区別は、公開前に実例で検証して調整する（docs/送信前チェック評価.md）。
 * 調整はこのファイルだけで完結させる。
 *
 * - reject：送信を止める（他者への攻撃・差別・脅迫）
 * - confirm：確認表示を挟み、確認後の再送（confirmed=true）を許可する（境界域）
 * - support：投稿は止めず、本人にだけ相談先を案内する（自分・子どもへの危害のほのめかし）
 */
export const REJECT_THRESHOLDS: Readonly<Record<string, { reason: Reason; score: number }>> = {
  "harassment": { reason: "harassment", score: 0.85 },
  "harassment/threatening": { reason: "threat", score: 0.5 },
  "hate": { reason: "hate", score: 0.7 },
  "hate/threatening": { reason: "threat", score: 0.5 },
};

export const CONFIRM_THRESHOLDS: Readonly<Record<string, { reason: Reason; score: number }>> = {
  "harassment": { reason: "harassment", score: 0.5 },
  "hate": { reason: "hate", score: 0.4 },
};

export const SUPPORT_THRESHOLDS: Readonly<Record<string, number>> = {
  "self-harm": 0.4,
  "self-harm/intent": 0.3,
  "self-harm/instructions": 0.3,
  "violence": 0.6,
};

function hits(
  scores: ModerationScores,
  table: Readonly<Record<string, { reason: Reason; score: number }>>,
): Reason[] {
  const reasons = new Set<Reason>();
  for (const [category, { reason, score }] of Object.entries(table)) {
    if ((scores[category] ?? 0) >= score) reasons.add(reason);
  }
  return [...reasons];
}

export function evaluateScores(scores: ModerationScores): {
  reject: Reason[];
  confirm: Reason[];
  supportNotice: boolean;
} {
  return {
    reject: hits(scores, REJECT_THRESHOLDS),
    confirm: hits(scores, CONFIRM_THRESHOLDS),
    supportNotice: Object.entries(SUPPORT_THRESHOLDS).some(
      ([category, score]) => (scores[category] ?? 0) >= score,
    ),
  };
}

/**
 * アップロード画像（アカウント画像）のreject閾値（設計案・未調整）。
 * 画像は確認表示を挟まず、不適切と判定されたら保存しない。顔・子どもの判別は行わない。
 */
export const IMAGE_REJECT_THRESHOLDS: Readonly<Record<string, number>> = {
  "sexual": 0.5,
  "sexual/minors": 0.1,
  "violence/graphic": 0.6,
  "self-harm/instructions": 0.5,
};

export function isImageRejected(scores: ModerationScores): boolean {
  return Object.entries(IMAGE_REJECT_THRESHOLDS).some(
    ([category, score]) => (scores[category] ?? 0) >= score,
  );
}
