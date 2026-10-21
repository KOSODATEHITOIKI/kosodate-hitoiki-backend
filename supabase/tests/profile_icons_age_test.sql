-- アイコン（profile_icons）と年齢帯の選択肢の検証（運営が決定・2026-10-21）。

BEGIN;
SELECT plan(11);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000e1'),
  ('00000000-0000-0000-0000-0000000000e2');

SELECT is(
  (SELECT string_agg(code, ',' ORDER BY sort_order) FROM public.profile_icons),
  'sun,sprout,little_bird,yellow_flower,tulip,blue_flowers',
  '選べるアイコンは6つ（太陽が初期）');

-- アイコン：決まったもの以外は入らない
SELECT lives_ok(
  $$INSERT INTO public.profiles (id, nickname, icon_key, child_age_range)
    VALUES ('00000000-0000-0000-0000-0000000000e1', 'あいこん', 'sun', 'age_0_1')$$,
  '決まったアイコンと年齢帯で、プロフィールを作れる');
SELECT throws_ok(
  $$UPDATE public.profiles SET icon_key = 'bear_01' WHERE id = '00000000-0000-0000-0000-0000000000e1'$$,
  '23503', NULL, '決まっていないアイコンは、外部キーで拒否される');
SELECT lives_ok(
  $$UPDATE public.profiles SET icon_key = NULL WHERE id = '00000000-0000-0000-0000-0000000000e1'$$,
  'アイコンは未選択（null）にできる');

-- 年齢帯：5区分と未選択だけ
SELECT lives_ok(
  $$UPDATE public.profiles SET child_age_range = v FROM (VALUES ('age_2_3'), ('age_4_6'), ('elementary'), ('junior_high_plus')) t(v)
    WHERE id = '00000000-0000-0000-0000-0000000000e1' AND v = 'junior_high_plus'$$,
  '決まった年齢帯を設定できる');
SELECT throws_ok(
  $$UPDATE public.profiles SET child_age_range = '0〜1歳' WHERE id = '00000000-0000-0000-0000-0000000000e1'$$,
  '23514', NULL, '決まっていない年齢帯（自由な文字列）は、check制約で拒否される');
SELECT lives_ok(
  $$UPDATE public.profiles SET child_age_range = NULL WHERE id = '00000000-0000-0000-0000-0000000000e1'$$,
  '年齢帯は未選択（null）にできる');

-- アップロード画像とイラストの排他は、これまでどおり
SELECT throws_ok(
  $$UPDATE public.profiles SET avatar_path = '00000000-0000-0000-0000-0000000000e1/a.png', icon_key = 'sun' WHERE id = '00000000-0000-0000-0000-0000000000e1'$$,
  '23514', NULL, 'アップロード画像とアイコンは、同時に設定できない');

-- profile_icons は、API（anon・authenticated）から読めない（アプリが画像の一覧を持つ。deny-by-default）
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT * FROM public.profile_icons$$, '42501', NULL, '未ログインは、profile_icons を読めない');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.profile_icons$$, '42501', NULL, 'ログイン済みも、profile_icons を読めない');
SELECT throws_ok($$INSERT INTO public.profile_icons (code) VALUES ('hacked')$$, '42501', NULL, 'ログイン済みは、アイコンを足せない');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
