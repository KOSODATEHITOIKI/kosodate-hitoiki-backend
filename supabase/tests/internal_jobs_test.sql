-- 内部ジョブの定期実行（invoke_internal_job・cron）と、秘密をVaultにだけ置く仕組み（job_secret_valid・setup_internal_jobs）の検証。
-- 実際にEdge Functionsを呼ぶ確認は、Supabaseのローカル環境で手動で行う（docs/運用手順.md）。
-- Vaultがない環境（素のPostgres）では、Vaultを使う部分はスキップする。

BEGIN;
SELECT plan(23);

-- === 定期実行の登録 ===
SELECT is(
  (SELECT schedule FROM cron.job WHERE jobname = 'internal-job-push-dispatch'),
  '* * * * *', 'プッシュ配信は1分ごとに呼ばれる');
SELECT is(
  (SELECT schedule FROM cron.job WHERE jobname = 'internal-job-storage-cleanup'),
  '*/10 * * * *', '画像の削除待ちの処理は10分ごとに呼ばれる');
SELECT is(
  (SELECT command FROM cron.job WHERE jobname = 'internal-job-push-dispatch'),
  $$select public.invoke_internal_job('push-dispatch')$$, '定期実行が呼ぶのは、許可した名前のジョブだけ');

SELECT throws_ok(
  $$SELECT public.invoke_internal_job('posts')$$, 'P0001', 'VALIDATION_FAILED',
  '許可していない名前（任意の関数）は呼べない');
SELECT throws_ok(
  $$SELECT public.invoke_internal_job('../rest/v1/profiles')$$, 'P0001', 'VALIDATION_FAILED',
  'パスを書き換えた名前は呼べない');

-- === 秘密の検証（Vaultの有無によらない部分） ===
SELECT is(public.job_secret_valid(NULL), false, '秘密がない（null）なら、正しくない');
SELECT is(public.job_secret_valid('short'), false, '形式が違う（64桁の16進数でない）なら、Vaultを読まずに拒否する');
SELECT is(public.job_secret_valid(repeat('0', 64)), false, '形式は正しいが登録された秘密と違う（または未登録）なら、正しくない');

-- 秘密と接続先が未登録の環境では、何も呼ばずに終わる（安全側）
SELECT is(public.invoke_internal_job('push-dispatch'), NULL, '秘密と接続先が未登録なら、何も呼ばない');
SELECT is(public.invoke_internal_job('storage-cleanup'), NULL, '（画像の削除待ちも同様）');

-- === Vaultを使う部分（Vaultがない環境ではスキップ） ===
CREATE FUNCTION pg_temp.vault_tests() RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE
  s1 text;
  s2 text;
  s3 text;
  msg text;
BEGIN
  IF to_regclass('vault.secrets') IS NULL THEN
    RETURN NEXT skip('Vaultがない環境', 9);
    RETURN;
  END IF;

  msg := public.setup_internal_jobs('https://abcdefghij.supabase.co');
  RETURN NEXT ok(msg LIKE '%新しく作りました%', 'setup_internal_jobs：秘密を新しく作る');
  EXECUTE 'select decrypted_secret from vault.decrypted_secrets where name = ''internal_job_secret''' INTO s1;
  RETURN NEXT is(length(s1), 64, '秘密は64文字（形式：64桁の16進数）');
  RETURN NEXT ok(s1 ~ '^[0-9a-f]{64}$', '秘密は16進数');
  RETURN NEXT is(public.job_secret_valid(s1), true, '登録された秘密は、正しいと判定される');

  msg := public.setup_internal_jobs('https://abcdefghij.supabase.co');
  EXECUTE 'select decrypted_secret from vault.decrypted_secrets where name = ''internal_job_secret''' INTO s2;
  RETURN NEXT ok(msg LIKE '%すでにあります%' AND s2 = s1, '2回目は、秘密を変えない（冪等）');

  msg := public.setup_internal_jobs('https://abcdefghij.supabase.co', true);
  EXECUTE 'select decrypted_secret from vault.decrypted_secrets where name = ''internal_job_secret''' INTO s3;
  RETURN NEXT ok(s3 <> s1 AND public.job_secret_valid(s3) AND NOT public.job_secret_valid(s1), '入れ替えると、新しい秘密だけが正しくなる（古い秘密は無効）');

  RETURN NEXT throws_ok($q$SELECT public.setup_internal_jobs('http://evil.example.com')$q$, 'P0001', 'VALIDATION_FAILED', '接続先は、https://<ref>.supabase.co の形だけ');
  RETURN NEXT throws_ok($q$SELECT public.setup_internal_jobs('https://evil.example.com')$q$, 'P0001', 'VALIDATION_FAILED', '（別のドメインへは、秘密つきのリクエストを送らせない）');

  EXECUTE 'select decrypted_secret from vault.decrypted_secrets where name = ''project_url''' INTO s1;
  RETURN NEXT is(s1, 'https://abcdefghij.supabase.co', '接続先が登録される（末尾のスラッシュは除く）');
END
$$;
SELECT * FROM pg_temp.vault_tests();

-- === 権限 ===
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.invoke_internal_job('push-dispatch')$$, '42501', NULL, '利用者は内部ジョブを呼べない');
SELECT throws_ok($$SELECT public.job_secret_valid(repeat('0', 64))$$, '42501', NULL, '利用者は秘密の検証を呼べない（総当たりに使わせない）');
SELECT throws_ok($$SELECT public.setup_internal_jobs('https://abcdefghij.supabase.co')$$, '42501', NULL, '利用者は設定を呼べない');
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT throws_ok($$SELECT public.setup_internal_jobs('https://abcdefghij.supabase.co')$$, '42501', NULL, 'Edge Functions（service_role）も、設定は呼べない（DBの管理者だけ）');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
