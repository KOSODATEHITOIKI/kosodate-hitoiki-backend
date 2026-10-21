-- ブロック中の相手の表示名を返す my_blocks の検証（Issue #75）。
-- 本人だけが読め、ブロックされた側・第三者・未ログインからは見えない（ブロックを推測させない）。

BEGIN;
SELECT plan(9);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000a1'), -- A：ブロックする側
  ('00000000-0000-0000-0000-0000000000a2'), -- B：ブロックされる側
  ('00000000-0000-0000-0000-0000000000a3'); -- C：第三者

INSERT INTO public.profiles (id, nickname, icon_key, avatar_path) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'えー', NULL, NULL),
  ('00000000-0000-0000-0000-0000000000a2', 'びー', 'bear_01', NULL),
  ('00000000-0000-0000-0000-0000000000a3', 'しー', NULL, '00000000-0000-0000-0000-0000000000a3/x.png');

-- 本人の設定として、AがBをブロックする（RLSの本人用ポリシー経由）
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2');

SELECT is(
  (SELECT count(*)::int FROM public.my_blocks), 1, 'ブロックした本人には、ブロックした相手が1件見える');
SELECT is(
  (SELECT blocked_nickname FROM public.my_blocks WHERE blocked_id = '00000000-0000-0000-0000-0000000000a2'),
  'びー', '相手のニックネームが取れる');
SELECT is(
  (SELECT blocked_icon_key FROM public.my_blocks WHERE blocked_id = '00000000-0000-0000-0000-0000000000a2'),
  'bear_01', '相手のアイコンが取れる');
SELECT is(
  (SELECT array_agg(attname::text ORDER BY attnum) FROM pg_attribute
   WHERE attrelid = 'public.my_blocks'::regclass AND attnum > 0 AND NOT attisdropped),
  ARRAY['blocked_id', 'blocked_nickname', 'blocked_icon_key', 'blocked_avatar_path', 'created_at'],
  '返す列は、相手のid・ニックネーム・アイコン・画像・ブロックした日時だけ（bioなどは含まない）');

-- ブロックされた側のBには、見えない（ブロックされている事実を推測させない）
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a2';
SELECT is((SELECT count(*)::int FROM public.my_blocks), 0, 'ブロックされた側からは、0件にしか見えない');

-- 第三者のCにも見えない
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a3';
SELECT is((SELECT count(*)::int FROM public.my_blocks), 0, '第三者からは、0件にしか見えない');

-- 解除すると、一覧から消える
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
DELETE FROM public.blocks WHERE blocked_id = '00000000-0000-0000-0000-0000000000a2';
SELECT is((SELECT count(*)::int FROM public.my_blocks), 0, '解除すると、一覧から消える');

-- 未ログイン（anon）は読めない
RESET role;
SET LOCAL role = 'anon';
SELECT throws_ok($$SELECT * FROM public.my_blocks$$, '42501', NULL, '未ログインは、my_blocks を読めない');
RESET role;

-- ブロックしたまま、相手のプロフィールが消えても（退会）、一覧は壊れない（blocks も一緒に消える）
DELETE FROM auth.users WHERE id = '00000000-0000-0000-0000-0000000000a3';
SELECT is((SELECT count(*)::int FROM public.blocks WHERE blocked_id = '00000000-0000-0000-0000-0000000000a3'), 0,
  '（参考）相手が退会しても、ブロックの行は残らない');

SELECT * FROM finish();
ROLLBACK;
