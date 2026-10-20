/**
 * 内部ジョブ（プッシュ配信・画像の削除待ちの処理など）を起動できる側の確認。
 *
 * 秘密は、DBのVaultにだけある（Edge Functionsのシークレットには置かない。2か所に置くと、食い違いが起きる）。
 * 受け取った秘密（x-job-secret ヘッダー）が正しいかは、DBに問い合わせて確かめる（job_secret_valid）。
 * 秘密がない・違う・Vaultに未登録のときは、どの場合も同じ拒否にする（存在を明かさない：呼び出し側には404）。
 *
 * 管理者が調べられるよう、拒否したことと、受け取った文字数だけをログに残す。秘密の値は、ログにも応答にも出さない。
 */
export type JobSecretVerifier = (given: string) => Promise<boolean>;

export async function jobSecretMatches(
  given: string | null,
  verify: JobSecretVerifier,
): Promise<boolean> {
  if (!given) return false; // 秘密のヘッダーがない呼び出しは、DBに問い合わせず、記録もしない（無関係なアクセス）
  try {
    if (await verify(given)) return true;
    console.error(
      `job-secret rejected: wrong or not registered in Vault (given_length=${given.length})`,
    );
    return false;
  } catch {
    // DBに問い合わせられなかった。安全側（拒否）に倒す。
    console.error("job-secret verification failed: could not reach the database");
    return false;
  }
}

export const JOB_SECRET_HEADER = "x-job-secret";
