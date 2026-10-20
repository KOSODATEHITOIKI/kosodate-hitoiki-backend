/**
 * 内部ジョブ（プッシュ配信・画像の削除待ちの処理など）を起動できる側の確認。
 * 定期実行だけが知る秘密（x-job-secret ヘッダー）と一致したときだけ通す。長さによらず同じ時間で比べ、
 * 秘密の一致を応答時間から推測させない。秘密が未設定のときは、誰も通さない。
 *
 * 拒否の理由は、利用者（呼び出し側）には返さない（存在を明かさないため、どの場合も404）。
 * 設定の食い違いを管理者が調べられるよう、**理由の種類と文字数だけ**をログに残す。
 * 秘密の値は、ログにも応答にも出さない。
 */
export async function jobSecretMatches(
  given: string | null,
  expected: string | undefined,
): Promise<boolean> {
  if (!expected) {
    // シークレット INTERNAL_JOB_SECRET が、この関数に届いていない（未登録・名前の違い・反映待ち）
    console.error("job-secret rejected: INTERNAL_JOB_SECRET is not set in this function");
    return false;
  }
  if (!given) return false; // 秘密のヘッダーがない呼び出しは、記録しない（無関係なアクセス）
  const hash = async (s: string) =>
    new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  const [a, b] = await Promise.all([hash(given), hash(expected)]);
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  if (diff !== 0) {
    // 値が違う。文字数の違い（前後の空白・改行の混入など）に気づけるよう、文字数だけ記録する。
    console.error(
      `job-secret rejected: mismatch (given_length=${given.length}, expected_length=${expected.length})`,
    );
    return false;
  }
  return true;
}

export const JOB_SECRET_HEADER = "x-job-secret";
