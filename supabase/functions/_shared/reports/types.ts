/** 通報・運営の対処のDB関数（RPC）の呼び出し。実装は wiring.ts、テストではフェイクを使う。 */
export type ReportReason =
  | "harassment"
  | "personal_info"
  | "spam"
  | "copyright"
  | "danger"
  | "other";

export type ModerationAction = "unhide" | "delete" | "warn" | "suspend" | "guide";

export interface ReportsDb {
  createReport(a: {
    reporterId: string;
    targetType: "post" | "comment";
    targetId: string;
    reason: ReportReason;
    detail: string | null;
  }): Promise<{ id: string; duplicate: boolean }>;
  /** admin_users に登録されているか（運営者かどうかの判定。二段階認証は別に確認する）。 */
  isRegisteredAdmin(userId: string): Promise<boolean>;
  applyModeration(a: {
    adminId: string;
    targetType: "post" | "comment" | "user";
    targetId: string;
    action: ModerationAction;
    reason: string | null;
  }): Promise<{ id: string; action: ModerationAction; restriction_stage: number | null }>;
}

export interface AuthContext {
  userId: string;
  /** Supabase Authが付与する認証保証レベル。二段階認証済みは "aal2"。 */
  aal: string;
}

export interface ReportsDeps {
  /** Authorizationヘッダーを検証し、ユーザーIDと認証保証レベルを返す。未ログインなら null。 */
  authenticate(req: Request): Promise<AuthContext | null>;
  db: ReportsDb;
}

/** DB関数が返す業務ルール違反。メッセージの内部コードだけを保持する。 */
export class ReportsRuleError extends Error {
  constructor(public readonly code: string) {
    super("rule violation");
    this.name = "ReportsRuleError";
  }
}

const RULE_CODES = new Set([
  "NOT_FOUND",
  "FORBIDDEN",
  "RESTRICTED",
  "PROFILE_REQUIRED",
  "VALIDATION_FAILED",
  "CONFLICT",
]);

/** PostgRESTのエラーを ReportsRuleError へ。コード以外（内部情報を含みうるもの）は捨てる。 */
export function toReportsError(e: { code?: string; message?: string }): Error {
  if (e.code === "P0001" && e.message && RULE_CODES.has(e.message)) {
    return new ReportsRuleError(e.message);
  }
  return new Error("database error");
}
