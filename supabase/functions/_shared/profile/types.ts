import type { ImageCheckDeps } from "../moderation/check.ts";
import type { CheckDeps } from "../moderation/types.ts";

/** DB操作。実装は wiring.ts（supabase-js＋service_role）、テストではフェイクを使う。 */
export interface ProfileDb {
  /** プロフィール・利用規約同意・通知設定を1トランザクションで作る（create_profile）。 */
  createProfile(args: {
    userId: string;
    nickname: string;
    bio: string | null;
    childAgeRange: string | null;
    iconKey: string | null;
    termsVersion: string;
  }): Promise<"created" | "exists" | "conflict">;
  changeNickname(userId: string, nickname: string): Promise<void>;
  /** 指定した項目だけ更新する。icon_key を設定するときは avatar_path を外す。 */
  updateProfile(
    userId: string,
    patch: { bio?: string | null; child_age_range?: string | null; icon_key?: string | null },
  ): Promise<void>;
  getAvatarPath(userId: string): Promise<string | null>;
  /** avatar_path を設定（icon_key は外す）、または null で外す。 */
  setAvatarPath(userId: string, path: string | null): Promise<void>;
}

export interface AvatarStorage {
  upload(path: string, bytes: Uint8Array, contentType: string): Promise<void>;
  remove(path: string): Promise<void>;
}

/** DB由来のエラー。PostgreSQLのSQLSTATEコードだけを保持し、メッセージ・本文は持たない。 */
export class DbError extends Error {
  constructor(public readonly code: string | undefined, public readonly hint?: string) {
    super("database error");
    this.name = "DbError";
  }
}

export interface ProfileDeps {
  /** Authorizationヘッダーを検証し、ユーザーIDを返す。未ログインなら null。 */
  authenticate(req: Request): Promise<string | null>;
  moderation: CheckDeps;
  imageModeration: ImageCheckDeps;
  db: ProfileDb;
  storage: AvatarStorage;
  /** テストで固定するための差し替え口。 */
  newId?: () => string;
}

/** トリガーが返す業務ルール違反のメッセージ（利用者に見せてよい文言だけ通す）。 */
const KNOWN_RULE_MESSAGES = new Set([
  "ニックネームは30日に1回まで変更できます",
  "この名前は現在使用できません",
]);

/** PostgRESTのエラーから、コードと利用者向けの文言だけを取り出す（生のメッセージは捨てる）。 */
export function toDbError(e: { code?: string; message?: string }): DbError {
  const hint = e.code === "P0001" && e.message && KNOWN_RULE_MESSAGES.has(e.message)
    ? e.message
    : undefined;
  return new DbError(e.code, hint);
}
