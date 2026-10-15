/** 退会（アカウント削除）。DBの withdraw_account が本体で、Edge Functionは本人確認と画像の削除を担う。 */
export interface AuthedUser {
  userId: string;
  /**
   * この操作に使われているセッション自身が作られた時刻（ISO 8601）。不明なら null。
   * ユーザー全体の最終ログイン時刻ではない：別の端末で本人が再ログインしても、
   * 盗まれた古いセッションが「直近のログイン」にならないようにするため。
   */
  sessionStartedAt: string | null;
}

export interface AccountDb {
  /** 運営者として登録されているか。 */
  isOperator(userId: string): Promise<boolean>;
  /** 退会（1トランザクション。何度実行しても安全）。 */
  withdraw(userId: string): Promise<"deleted" | "already_deleted">;
}

export interface AccountStorage {
  /** そのユーザーがアップロードした画像をすべて削除する（なければ何もしない）。 */
  removeAllFor(userId: string): Promise<void>;
}

export interface AccountDeps {
  /** Authorizationヘッダーを検証する。未ログインなら null。 */
  authenticate(req: Request): Promise<AuthedUser | null>;
  db: AccountDb;
  storage: AccountStorage;
  /** テストで固定するための差し替え口。 */
  now?: () => number;
}

/** DB関数が返す業務ルール違反。 */
export class AccountRuleError extends Error {
  constructor(public readonly code: string) {
    super("rule violation");
    this.name = "AccountRuleError";
  }
}

/** PostgRESTのエラーを AccountRuleError へ。コード以外（内部情報を含みうるもの）は捨てる。 */
export function toAccountError(e: { code?: string; message?: string }): Error {
  if (e.code === "P0001" && e.message === "OPERATOR_REGISTERED") {
    return new AccountRuleError(e.message);
  }
  return new Error("database error");
}
