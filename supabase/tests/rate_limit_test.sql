-- 登録直後の投稿・コメントの制限と、新規登録の停止、運営設定の変更の検証（Issue #18）。
-- 同時の作成で上限を超えないことは、pgTAPでは検証できないため supabase/tests/concurrency/run.sh で検証する。

BEGIN;
SELECT plan(30);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000c1'), -- 新規の利用者
  ('00000000-0000-0000-0000-0000000000c2'), -- 登録から時間が経った利用者
  ('00000000-0000-0000-0000-0000000000c3'), -- 運営者
  ('00000000-0000-0000-0000-0000000000c4'), -- 投稿者（コメントを受ける側）
  ('00000000-0000-0000-0000-0000000000c5'), -- 運営者ではない人
  ('00000000-0000-0000-0000-0000000000c6'); -- プロフィール未作成

INSERT INTO public.profiles (id, nickname, created_at) VALUES
  ('00000000-0000-0000-0000-0000000000c1', 'しんき', now()),
  ('00000000-0000-0000-0000-0000000000c2', 'ふるい', now() - interval '25 hours'),
  ('00000000-0000-0000-0000-0000000000c3', 'うんえいしゃ', now()),
  ('00000000-0000-0000-0000-0000000000c4', 'とうこうぬし', now() - interval '48 hours'),
  ('00000000-0000-0000-0000-0000000000c5', 'いっぱん', now());

INSERT INTO public.admin_users (user_id) VALUES ('00000000-0000-0000-0000-0000000000c3');

-- 初期値
SELECT is(
  (SELECT value FROM public.app_settings WHERE key = 'new_user_limit'),
  '{"enabled": true, "window_hours": 24, "max_posts": 1, "max_comments": 3}'::jsonb,
  '初期値：登録後24時間は、投稿1件・コメント3件'
);
SELECT is((SELECT value FROM public.app_settings WHERE key = 'new_signup_halted'), 'false'::jsonb,
  '初期値：新規登録は停止していない');

-- === 投稿の制限 ===
SELECT lives_ok(
  $$SELECT public.create_post('00000000-0000-0000-0000-0000000000c1', 'guchi', null, '1件目', 'quiet_support', null)$$,
  '新規の利用者は、1件目の投稿を作れる');

SELECT throws_ok(
  $$SELECT public.create_post('00000000-0000-0000-0000-0000000000c1', 'guchi', null, '2件目', 'quiet_support', null)$$,
  'P0001', 'RATE_LIMITED', '新規の利用者は、2件目の投稿を作れない');

-- 削除しても回数は戻らない
DELETE FROM public.posts WHERE author_id = '00000000-0000-0000-0000-0000000000c1';
SELECT throws_ok(
  $$SELECT public.create_post('00000000-0000-0000-0000-0000000000c1', 'guchi', null, '消して再投稿', 'quiet_support', null)$$,
  'P0001', 'RATE_LIMITED', '投稿を削除しても、回数は戻らない（消して再投稿はできない）');

SELECT is(
  (SELECT count(*)::int FROM public.posts WHERE author_id = '00000000-0000-0000-0000-0000000000c1'), 0,
  '制限で拒否された投稿は保存されない');

-- 制限が解ける日時が、DETAILに入る
SELECT is(
  (SELECT count(*)::int FROM public.write_events WHERE user_id = '00000000-0000-0000-0000-0000000000c1' AND kind = 'post'), 1,
  '拒否された試行は、回数に数えない');

-- 再送（Idempotency-Key）は数えない
SELECT lives_ok(
  $$SELECT public.create_post('00000000-0000-0000-0000-0000000000c5', 'guchi', null, '再送の投稿', 'quiet_support', 'key-retry-1')$$,
  '1件目（キーつき）');
SELECT is(
  public.create_post('00000000-0000-0000-0000-0000000000c5', 'guchi', null, '再送の投稿', 'quiet_support', 'key-retry-1') ->> 'id',
  (SELECT id::text FROM public.posts WHERE author_id = '00000000-0000-0000-0000-0000000000c5'),
  '同じキーの再送は、制限に当たらず、同じ結果を返す');
SELECT is(
  (SELECT count(*)::int FROM public.write_events WHERE user_id = '00000000-0000-0000-0000-0000000000c5'), 1,
  '再送は、回数に数えない');

-- 窓を過ぎた利用者・運営者は対象外
SELECT lives_ok(
  $$SELECT public.create_post('00000000-0000-0000-0000-0000000000c2', 'guchi', null, 'a', 'quiet_support', null);
    SELECT public.create_post('00000000-0000-0000-0000-0000000000c2', 'guchi', null, 'b', 'quiet_support', null)$$,
  '登録から24時間を過ぎた利用者は、制限されない');
SELECT lives_ok(
  $$SELECT public.create_post('00000000-0000-0000-0000-0000000000c3', 'guchi', null, 'a', 'quiet_support', null);
    SELECT public.create_post('00000000-0000-0000-0000-0000000000c3', 'guchi', null, 'b', 'quiet_support', null)$$,
  '運営者は、制限されない');

-- === コメントの制限（3件まで） ===
INSERT INTO public.posts (id, author_id, post_type, body, reaction_mode, comment_acceptance)
VALUES ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000c4', 'soudan', '相談', 'want_comments', 'open');

SELECT lives_ok(
  $$SELECT public.create_comment('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000e1', null, 'c1', null);
    SELECT public.create_comment('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000e1', null, 'c2', null);
    SELECT public.create_comment('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000e1', null, 'c3', null)$$,
  '新規の利用者は、コメントを3件まで作れる');
SELECT throws_ok(
  $$SELECT public.create_comment('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000e1', null, 'c4', null)$$,
  'P0001', 'RATE_LIMITED', '4件目のコメントは作れない');

-- 拒否される条件（受付終了）は、回数に数えない
UPDATE public.posts SET comment_acceptance = 'closed' WHERE id = '00000000-0000-0000-0000-0000000000e1';
SELECT throws_ok(
  $$SELECT public.create_comment('00000000-0000-0000-0000-0000000000c5', '00000000-0000-0000-0000-0000000000e1', null, 'x', null)$$,
  'P0001', 'COMMENTS_CLOSED', '受付終了のコメントは、制限ではなく受付終了で拒否される');
SELECT is(
  (SELECT count(*)::int FROM public.write_events WHERE user_id = '00000000-0000-0000-0000-0000000000c5' AND kind = 'comment'), 0,
  '受付終了で拒否されたコメントは、回数に数えない');

-- === 設定の変更が効く ===
UPDATE public.app_settings SET value = '{"enabled": true, "window_hours": 24, "max_posts": 2, "max_comments": 3}' WHERE key = 'new_user_limit';
SELECT lives_ok(
  $$SELECT public.create_post('00000000-0000-0000-0000-0000000000c1', 'guchi', null, '上限を上げた後', 'quiet_support', null)$$,
  '上限を2件に上げると、2件目を作れる');

UPDATE public.app_settings SET value = jsonb_set(value, '{enabled}', 'false') WHERE key = 'new_user_limit';
SELECT lives_ok(
  $$SELECT public.create_post('00000000-0000-0000-0000-0000000000c1', 'guchi', null, '無効化後', 'quiet_support', null)$$,
  '制限を無効にすると、上限を超えて作れる');
UPDATE public.app_settings SET value = jsonb_set(value, '{enabled}', 'true') WHERE key = 'new_user_limit';

-- === 運営設定の変更：set_app_setting ===
SELECT is(
  public.set_app_setting('00000000-0000-0000-0000-0000000000c3', 'new_signup_halted', 'true'::jsonb) ->> 'key',
  'new_signup_halted', '運営者は、新規登録を停止できる');
SELECT is((SELECT value FROM public.app_settings WHERE key = 'new_signup_halted'), 'true'::jsonb, '停止が保存される');
SELECT is(
  (SELECT old_value || to_jsonb(new_value) FROM public.app_settings_history WHERE key = 'new_signup_halted'),
  '[false, true]'::jsonb, '変更履歴に、前の値と新しい値が残る');
SELECT is(
  (SELECT changed_by FROM public.app_settings_history WHERE key = 'new_signup_halted'),
  '00000000-0000-0000-0000-0000000000c3'::uuid, '変更履歴に、変更した運営者が残る');

SELECT throws_ok(
  $$SELECT public.set_app_setting('00000000-0000-0000-0000-0000000000c5', 'new_signup_halted', 'false'::jsonb)$$,
  'P0001', 'FORBIDDEN', '運営者でない人は、設定を変えられない');
SELECT throws_ok(
  $$SELECT public.set_app_setting('00000000-0000-0000-0000-0000000000c3', 'new_signup_halted', '"yes"'::jsonb)$$,
  'P0001', 'VALIDATION_FAILED', '形が違う値は拒否される（停止は真偽値）');
SELECT throws_ok(
  $$SELECT public.set_app_setting('00000000-0000-0000-0000-0000000000c3', 'new_user_limit', '{"enabled": true, "window_hours": 0, "max_posts": 1, "max_comments": 3}'::jsonb)$$,
  'P0001', 'VALIDATION_FAILED', '範囲外の値は拒否される');
SELECT throws_ok(
  $$SELECT public.set_app_setting('00000000-0000-0000-0000-0000000000c3', 'unknown_key', '1'::jsonb)$$,
  'P0001', 'VALIDATION_FAILED', '未知のキーは作れない');

-- === 新規登録の停止（停止中：プロフィールの新規作成を止め、作成済みの再送は通す） ===
SELECT throws_ok(
  $$SELECT public.create_profile('00000000-0000-0000-0000-0000000000c6', 'あたらしい', null, null, null, 'v1')$$,
  'P0001', 'SIGNUP_HALTED', '停止中は、プロフィールを新しく作れない');
SELECT is(
  public.create_profile('00000000-0000-0000-0000-0000000000c5', 'いっぱん', null, null, null, 'v1'),
  'exists', '停止中でも、作成済みの再送は成功を返す');

-- Authのフック：停止中はユーザーの作成を拒否し、停止していなければ通す
SELECT is(
  public.hook_before_user_created('{}'::jsonb) -> 'error' ->> 'http_code', '429', '停止中、Authのフックは作成を拒否する');
SELECT public.set_app_setting('00000000-0000-0000-0000-0000000000c3', 'new_signup_halted', 'false'::jsonb);
SELECT is(public.hook_before_user_created('{}'::jsonb), '{}'::jsonb, '再開すると、Authのフックは作成を通す');

SELECT * FROM finish();
ROLLBACK;
