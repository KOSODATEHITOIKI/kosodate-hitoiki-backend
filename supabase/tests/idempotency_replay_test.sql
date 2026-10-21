-- 再送（保存済みの結果の取り出し）と、相談先の案内の記録の検証（外部レビューの指摘への対応）。
-- 保存済みの結果を、外部API（送信前チェック）を呼ぶ前に返せることが目的。

BEGIN;
SELECT plan(10);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000e1'),
  ('00000000-0000-0000-0000-0000000000e2');
INSERT INTO public.profiles (id, nickname, created_at) VALUES
  ('00000000-0000-0000-0000-0000000000e1', 'さいそうしゃ', now() - interval '3 days'),
  ('00000000-0000-0000-0000-0000000000e2', 'べつのひと', now() - interval '3 days');

CREATE TEMP TABLE created AS
SELECT public.create_post(
  '00000000-0000-0000-0000-0000000000e1', 'guchi', NULL, '本文です', 'quiet_support', 'key-1'
) AS result;

SELECT is(
  public.replay_idempotent_response('00000000-0000-0000-0000-0000000000e1', 'post', 'key-1'),
  (SELECT result FROM created),
  '完了済みのキーは、最初の結果（id・作成日時）をそのまま返す');
SELECT is(
  public.replay_idempotent_response('00000000-0000-0000-0000-0000000000e1', 'post', 'unknown'),
  NULL, '未登録のキーは null');

SELECT public.remember_support_notice('00000000-0000-0000-0000-0000000000e1', 'post', 'key-1');
SELECT is(
  public.replay_idempotent_response('00000000-0000-0000-0000-0000000000e1', 'post', 'key-1'),
  (SELECT result FROM created) || '{"support_notice": true}'::jsonb,
  '相談先の案内を記録すると、再送の結果にも含まれる（結果のidは変わらない）');

SELECT is(
  public.replay_idempotent_response('00000000-0000-0000-0000-0000000000e2', 'post', 'key-1'),
  NULL, '別の利用者のキーは、返さない（利用者ごと）');

INSERT INTO public.idempotency_keys (user_id, endpoint, key)
VALUES ('00000000-0000-0000-0000-0000000000e1', 'post.create', 'in-progress');
SELECT is(
  public.replay_idempotent_response('00000000-0000-0000-0000-0000000000e1', 'post', 'in-progress'),
  NULL, '処理中（結果がまだない）のキーは null。通常の処理に進む');

SELECT is(
  public.replay_idempotent_response('00000000-0000-0000-0000-0000000000e1', 'edit', 'key-1'),
  NULL, '投稿・コメント以外の種類は null');

INSERT INTO public.idempotency_keys (user_id, endpoint, key, response, created_at)
VALUES ('00000000-0000-0000-0000-0000000000e1', 'post.create', 'expired', '{"id": "x"}', now() - interval '25 hours');
SELECT is(
  public.replay_idempotent_response('00000000-0000-0000-0000-0000000000e1', 'post', 'expired'),
  NULL, '24時間を過ぎたキーは返さない');

-- 権限：service_role専用
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.replay_idempotent_response('00000000-0000-0000-0000-0000000000e1', 'post', 'key-1')$$,
  '42501', NULL, '利用者は、保存済みの結果を取り出せない');
SELECT throws_ok(
  $$SELECT public.remember_support_notice('00000000-0000-0000-0000-0000000000e1', 'post', 'key-1')$$,
  '42501', NULL, '利用者は、相談先の案内を書き換えられない');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT throws_ok(
  $$SELECT public.replay_idempotent_response('00000000-0000-0000-0000-0000000000e1', 'post', 'key-1')$$,
  '42501', NULL, '未ログインは、保存済みの結果を取り出せない');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
