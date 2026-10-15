-- 公開前レビューの指摘への対処の検証：画像の削除待ち・外部API前の確認・セッションの作成時刻。

BEGIN;
SELECT plan(28);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000f1'), -- 新規の利用者
  ('00000000-0000-0000-0000-0000000000f2'), -- 登録から時間が経った利用者
  ('00000000-0000-0000-0000-0000000000f3'), -- 利用停止中
  ('00000000-0000-0000-0000-0000000000f4'); -- プロフィール未登録

INSERT INTO public.profiles (id, nickname, created_at) VALUES
  ('00000000-0000-0000-0000-0000000000f1', 'しんきのひと', now()),
  ('00000000-0000-0000-0000-0000000000f2', 'ふるいひと', now() - interval '3 days'),
  ('00000000-0000-0000-0000-0000000000f3', 'ていしのひと', now() - interval '3 days');
INSERT INTO public.account_restrictions (user_id, stage, ends_at, created_by)
VALUES ('00000000-0000-0000-0000-0000000000f3', 1, now() + interval '7 days', NULL);

-- === 画像の削除待ち ===
UPDATE public.profiles SET avatar_path = '00000000-0000-0000-0000-0000000000f2/old.png'
WHERE id = '00000000-0000-0000-0000-0000000000f2';
SELECT is((SELECT count(*)::int FROM public.pending_storage_deletions), 0, '画像を設定しただけでは、削除待ちにならない');

UPDATE public.profiles SET avatar_path = '00000000-0000-0000-0000-0000000000f2/new.png'
WHERE id = '00000000-0000-0000-0000-0000000000f2';
SELECT is((SELECT path FROM public.pending_storage_deletions), '00000000-0000-0000-0000-0000000000f2/old.png',
  '画像を差し替えると、古い画像が削除待ちに記録される');

UPDATE public.profiles SET avatar_path = NULL, icon_key = 'bear' WHERE id = '00000000-0000-0000-0000-0000000000f2';
SELECT is((SELECT count(*)::int FROM public.pending_storage_deletions WHERE path = '00000000-0000-0000-0000-0000000000f2/new.png'), 1,
  'イラストに変えて画像を外したときも、画像が削除待ちに記録される（パスが消えて画像だけ残らない）');

UPDATE public.profiles SET avatar_path = '00000000-0000-0000-0000-0000000000f2/last.png', icon_key = NULL
WHERE id = '00000000-0000-0000-0000-0000000000f2';
DELETE FROM public.profiles WHERE id = '00000000-0000-0000-0000-0000000000f2';
SELECT is((SELECT count(*)::int FROM public.pending_storage_deletions WHERE path = '00000000-0000-0000-0000-0000000000f2/last.png'), 1,
  'プロフィールの削除（退会）でも、画像が削除待ちに記録される');

SELECT is((SELECT count(*)::int FROM public.claim_storage_deletions(10)), 3, '削除待ちを取り出せる');
SELECT public.finish_storage_deletion('avatars', '00000000-0000-0000-0000-0000000000f2/old.png', false, 'STORAGE_503');
SELECT is((SELECT attempts || ':' || last_error FROM public.pending_storage_deletions WHERE path = '00000000-0000-0000-0000-0000000000f2/old.png'),
  '1:STORAGE_503', '削除に失敗したら、行が残り、回数とエラーコードが記録される');
SELECT public.finish_storage_deletion('avatars', '00000000-0000-0000-0000-0000000000f2/old.png', false, 'select * from secrets');
SELECT is((SELECT last_error FROM public.pending_storage_deletions WHERE path = '00000000-0000-0000-0000-0000000000f2/old.png'),
  'UNKNOWN', 'コードの形でないエラーは記録しない');
SELECT public.finish_storage_deletion('avatars', '00000000-0000-0000-0000-0000000000f2/old.png', true);
SELECT is((SELECT count(*)::int FROM public.pending_storage_deletions WHERE path = '00000000-0000-0000-0000-0000000000f2/old.png'), 0,
  '削除に成功したら、行が消える');

-- 注意：Auth（GoTrue）の権限（supabase_auth_admin）でのユーザー削除は、pgTAPからロールを切り替えられないため、
-- 結合テスト（functions/_shared/profile/images.integration.ts）で、本物のAuthのユーザー削除で確認している。

-- === 外部API前の確認：操作の資格 ===
SELECT throws_ok($$SELECT public.preflight_write('00000000-0000-0000-0000-0000000000f3', 'post')$$, 'P0001', 'RESTRICTED',
  '利用停止中は、投稿の作成の前に止まる');
SELECT throws_ok($$SELECT public.preflight_write('00000000-0000-0000-0000-0000000000f3', 'edit')$$, 'P0001', 'RESTRICTED',
  '利用停止中は、編集の前に止まる');
SELECT lives_ok($$SELECT public.preflight_write('00000000-0000-0000-0000-0000000000f3', 'profile')$$,
  '利用停止中でも、プロフィールの操作は止めない（従来どおり）');
SELECT throws_ok($$SELECT public.preflight_write('00000000-0000-0000-0000-0000000000f4', 'comment')$$, 'P0001', 'PROFILE_REQUIRED',
  'プロフィール未登録は、コメントの前に止まる');
SELECT throws_ok($$SELECT public.preflight_write('00000000-0000-0000-0000-0000000000f1', 'bogus')$$, 'P0001', 'VALIDATION_FAILED',
  '未知の種類は拒否される');

-- === 外部API前の確認：登録直後の上限（数えずに判定する） ===
INSERT INTO public.write_events (user_id, kind) VALUES ('00000000-0000-0000-0000-0000000000f1', 'post');
SELECT throws_ok($$SELECT public.preflight_write('00000000-0000-0000-0000-0000000000f1', 'post')$$, 'P0001', 'RATE_LIMITED',
  '登録直後の上限に達していたら、外部APIを呼ぶ前に止まる');
SELECT is((SELECT count(*)::int FROM public.write_events WHERE user_id = '00000000-0000-0000-0000-0000000000f1'), 1,
  '確認だけでは、作成の回数を増やさない');
SELECT is((SELECT coalesce(sum(request_count), 0)::int FROM public.request_budget WHERE user_id = '00000000-0000-0000-0000-0000000000f1'), 0,
  '上限で止まった確認は、リクエスト数に数えない');
SELECT lives_ok($$SELECT public.preflight_write('00000000-0000-0000-0000-0000000000f1', 'comment')$$,
  'コメントの上限は別（投稿が上限でもコメントは通る）');


-- 完了済みのIdempotency-Keyの再送は、登録直後の上限に当たらない（最初の結果を返せるように）
INSERT INTO public.idempotency_keys (user_id, endpoint, key, response)
VALUES ('00000000-0000-0000-0000-0000000000f1', 'post.create', 'done-key', '{"id":"x"}'::jsonb),
       ('00000000-0000-0000-0000-0000000000f1', 'post.create', 'pending-key', NULL);
SELECT lives_ok($$SELECT public.preflight_write('00000000-0000-0000-0000-0000000000f1', 'post', 'done-key')$$,
  '上限に達していても、完了済みのキーの再送は止めない');
SELECT throws_ok($$SELECT public.preflight_write('00000000-0000-0000-0000-0000000000f1', 'post', 'pending-key')$$, 'P0001', 'RATE_LIMITED',
  '処理中（結果のない）キーや新しいキーは、上限の判定を受ける');

-- === 外部API前の確認：利用者ごとのリクエスト上限（テキスト30回／10分） ===
DELETE FROM public.request_budget;
SELECT lives_ok(
  $$SELECT public.preflight_write('00000000-0000-0000-0000-0000000000f3', 'profile') FROM generate_series(1, 30)$$,
  '10分に30回までは通る');
SELECT throws_ok($$SELECT public.preflight_write('00000000-0000-0000-0000-0000000000f3', 'profile')$$, 'P0001', 'REQUEST_LIMITED',
  '31回目は、外部APIを呼ぶ前に止まる');

-- 画像は別枠（10回／10分）
SELECT lives_ok(
  $$SELECT public.preflight_write('00000000-0000-0000-0000-0000000000f3', 'image') FROM generate_series(1, 10)$$,
  '画像は10回までは通る（テキストの枠とは別）');
SELECT throws_ok($$SELECT public.preflight_write('00000000-0000-0000-0000-0000000000f3', 'image')$$, 'P0001', 'REQUEST_LIMITED',
  '画像の11回目は止まる');

-- === セッションの作成時刻 ===
INSERT INTO auth.sessions (id, user_id, created_at) VALUES
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000f1', now() - interval '2 days'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000f1', now());
SELECT ok(public.session_started_at('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000f1') < now() - interval '1 day',
  '古いセッションは、作成時刻が古い（別のセッションが新しくても影響しない）');
SELECT ok(public.session_started_at('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000f1') > now() - interval '1 minute',
  '新しいセッションは、作成時刻が新しい');
SELECT is(public.session_started_at('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000f2'), NULL,
  '別の利用者のセッションIDでは、時刻を返さない');

-- === 利用者からは呼べない・読めない ===
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.preflight_write('00000000-0000-0000-0000-0000000000f1', 'post')$$, '42501', NULL, '利用者は preflight_write を呼べない');
SELECT throws_ok($$SELECT count(*) FROM public.pending_storage_deletions$$, '42501', NULL, '利用者は削除待ちを読めない');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
