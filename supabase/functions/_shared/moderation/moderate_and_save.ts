import { checkLocal, checkText } from "./check.ts";
import type { CheckDeps, CheckResult } from "./types.ts";

export type Fields = Readonly<Record<string, string>>;

export interface ModerateAndSaveResult<T> {
  result: CheckResult;
  /** decision が allow のときだけ入る。 */
  saved?: T;
}

/**
 * 送信前チェックと保存を1つの経路にまとめる。
 *
 * `save` に渡るのは「チェックを通した文字列そのもの」（凍結済み）。呼び出し側は保存時に
 * この引数だけを使う。チェック後に本文を書き換えたり、クライアントが申告した本文・結果を
 * 使ったりしない（チェックした本文と保存本文の一致、docs/バックエンド設計.md 4節）。
 * 保存はEdge Functions（service_role）だけが行う（RLSでクライアントの直接書き込みは不可）。
 *
 * 複数フィールド（ニックネームと自己紹介等）は全てを判定し、最も厳しい結果に揃える。
 * 外部APIが使えない場合は ModerationUnavailableError がそのまま伝わり、保存は行われない。
 */
export async function moderateAndSave<T>(
  fields: Fields,
  deps: CheckDeps,
  options: { confirmed?: boolean },
  save: (verified: Fields) => Promise<T>,
): Promise<ModerateAndSaveResult<T>> {
  const verified: Fields = Object.freeze({ ...fields });

  // 先にローカル判定（禁止語・個人情報）を全フィールドで行い、該当があれば外部APIを呼ばずに reject する。
  const localRejects = Object.values(verified).map(checkLocal).filter((r) => r !== null);
  if (localRejects.length > 0) {
    return {
      result: {
        decision: "reject",
        reasons: [...new Set(localRejects.flatMap((r) => r.reasons))],
        supportNotice: false,
      },
    };
  }

  const results: CheckResult[] = [];
  for (const text of Object.values(verified)) {
    results.push(await checkText(text, deps, options));
  }

  const decision = results.some((r) => r.decision === "reject")
    ? "reject"
    : results.some((r) => r.decision === "confirm")
    ? "confirm"
    : "allow";
  const result: CheckResult = {
    decision,
    reasons: [...new Set(results.flatMap((r) => r.reasons))],
    supportNotice: results.some((r) => r.supportNotice),
  };

  if (decision !== "allow") return { result };
  return { result, saved: await save(verified) };
}
