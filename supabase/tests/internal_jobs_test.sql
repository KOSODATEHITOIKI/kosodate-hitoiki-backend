-- 内部ジョブの定期実行（invoke_internal_job と cron の登録）の検証。
-- 実際にEdge Functionsを呼ぶ確認は、Supabaseのローカル環境で手動で行う（docs/運用手順.md）。

BEGIN;
SELECT plan(8);

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

-- 秘密・接続先が未登録の環境では、何も呼ばずに終わる（安全側）
SELECT is(public.invoke_internal_job('push-dispatch'), NULL, '秘密と接続先が未登録なら、何も呼ばない');
SELECT is(public.invoke_internal_job('storage-cleanup'), NULL, '（画像の削除待ちも同様）');

-- 利用者からは呼べない
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.invoke_internal_job('push-dispatch')$$, '42501', NULL, '利用者は内部ジョブを呼べない');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
