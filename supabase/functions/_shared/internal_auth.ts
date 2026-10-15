/**
 * 内部ジョブ（プッシュ配信・画像の削除待ちの処理など）を起動できる側の確認。
 * 定期実行だけが知る秘密（x-job-secret ヘッダー）と一致したときだけ通す。長さによらず同じ時間で比べ、
 * 秘密の一致を応答時間から推測させない。秘密が未設定のときは、誰も通さない。
 */
export async function jobSecretMatches(
  given: string | null,
  expected: string | undefined,
): Promise<boolean> {
  if (!expected || !given) return false;
  const hash = async (s: string) =>
    new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  const [a, b] = await Promise.all([hash(given), hash(expected)]);
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export const JOB_SECRET_HEADER = "x-job-secret";
