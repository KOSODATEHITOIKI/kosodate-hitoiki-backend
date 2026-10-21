-- 共感・定型文の固定の名前（code）の検証（Issue #75）。

BEGIN;
SELECT plan(8);

INSERT INTO public.reaction_types (code, label, sort_order) VALUES
  ('empathy', 'わかる', 1),
  ('take_a_break', 'おつかれさま', 2);
INSERT INTO public.reaction_types (label, sort_order) VALUES ('コードなし', 3);

SELECT is((SELECT count(*)::int FROM public.reaction_types WHERE code IS NULL), 1, 'codeなしの定型文も作れる（アイコンとの対応がない）');
SELECT throws_ok(
  $$INSERT INTO public.reaction_types (code, label) VALUES ('empathy', '重複')$$,
  '23505', NULL, 'codeは重複できない');
SELECT lives_ok(
  $$INSERT INTO public.reaction_types (label) VALUES ('コードなし2')$$,
  'codeがnullの行は、複数あってよい');
SELECT throws_ok(
  $$INSERT INTO public.reaction_types (code, label) VALUES ('Empathy', '大文字')$$,
  '23514', NULL, 'codeは英小文字・数字・_だけ（大文字は拒否）');
SELECT throws_ok(
  $$INSERT INTO public.reaction_types (code, label) VALUES ('a', '短すぎる')$$,
  '23514', NULL, 'codeは2文字以上');

-- 未ログイン・ログイン済みの両方が、codeを含めて読める（公開マスタ）
SET LOCAL role = 'anon';
SELECT is(
  (SELECT string_agg(code, ',' ORDER BY sort_order) FROM public.reaction_types WHERE code IS NOT NULL),
  'empathy,take_a_break', '未ログインでも、codeと文言を読める');
SELECT throws_ok(
  $$INSERT INTO public.reaction_types (code, label) VALUES ('x_y', '書けない')$$,
  '42501', NULL, '未ログインは、定型文を書き換えられない');
RESET role;
SET LOCAL role = 'authenticated';
SELECT throws_ok(
  $$UPDATE public.reaction_types SET label = '書き換え'$$,
  '42501', NULL, 'ログイン済みも、定型文を書き換えられない（運営だけ）');
RESET role;

SELECT * FROM finish();
ROLLBACK;
