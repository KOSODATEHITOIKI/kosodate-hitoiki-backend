/** 送信前チェックの判定結果（docs/バックエンド設計.md 4節、docs/API契約.md エラーコード）。 */
export type Decision = "allow" | "confirm" | "reject";

/** 判定理由。本文そのものは含めない（ログ・レスポンスへ本文を漏らさないため）。 */
export type Reason =
  | "banned_word"
  | "pii_phone"
  | "pii_email"
  | "pii_postal_code"
  | "pii_address"
  | "harassment"
  | "hate"
  | "threat"
  | "image_inappropriate";

export interface CheckResult {
  decision: Decision;
  reasons: Reason[];
  /**
   * 自分や子どもへの危害をほのめかす表現を検出した。投稿は止めず、本人にだけ相談先を案内する。
   * 他の利用者へは公開しない（レスポンスを返すのは書き込んだ本人のみ）。
   */
  supportNotice: boolean;
}

/** OpenAI Moderation APIの category_scores（カテゴリ名 → 0〜1のスコア）。 */
export type ModerationScores = Readonly<Record<string, number>>;

export interface CheckDeps {
  /** 外部Moderation API。失敗時は ModerationUnavailableError を投げる。 */
  moderate: (text: string) => Promise<ModerationScores>;
}

/** 外部Moderation APIが使えない。保存はブロックし、再試行を促す（決定済み）。 */
export class ModerationUnavailableError extends Error {
  constructor(message = "moderation service unavailable") {
    super(message);
    this.name = "ModerationUnavailableError";
  }
}
