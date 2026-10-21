-- マスタの初期データ（定型文・話題）。dev・本番とも、Supabaseの SQL Editor で手動で実行する（管理者の作業）。
-- マイグレーションには入れない（マスタの文言は運営が直すため。ローカルのテストにも影響させない）。
-- 何度実行しても同じ結果になる。決定の経緯は docs/未決事項.md。
--
-- 定型文：運営が用意した少数の種類から、1人1つ（Notion決定）。codeは、画面のアイコンと結びつける固定の名前。
-- 文言を直すときは、labelだけを直す（codeは変えない）。
insert into public.reaction_types (code, label, sort_order) values
  ('empathy',      'わかる',         1),
  ('take_a_break', 'おつかれさま',   2),
  ('listening',    '聞いているよ',   3),
  ('gentle_cheer', 'そっと応援',     4),
  ('applause',     'がんばってるね', 5)
on conflict (code) where code is not null
do update set label = excluded.label, sort_order = excluded.sort_order, is_active = true;

-- 話題：投稿に1つ（任意）付け、絞り込みとミュートに使う。「その他」は作らず、話題を付けない（null）で表す。
-- 文言を直すときは、同じ順（sort_order）の行のlabelを、手で直す（idは変えない）。
insert into public.topics (label, sort_order)
select v.label, v.sort_order
from (values
  ('睡眠・夜泣き',           1),
  ('食事・離乳食',           2),
  ('保育園・幼稚園・学校',   3),
  ('仕事と育児の両立',       4),
  ('夫婦・パートナー',       5),
  ('家族・親戚との関係',     6),
  ('自分の時間・心の疲れ',   7),
  ('健康・病気',             8),
  ('成長・発達',             9),
  ('お金・暮らし',           10)
) as v(label, sort_order)
where not exists (select 1 from public.topics t where t.label = v.label);
