-- プロフィールのアイコン（イラスト）と、子どもの年齢帯の選択肢を確定する（運営が決定・2026-10-21）。
-- これまでは、どちらも自由な文字列で、公開情報（アイコン）に、想定外の値が入り得た。

-- === アイコン（イラスト）：マスタとFK ===
-- アイコンは、アプリに同梱する画像と対応する（画像を足すにはアプリの更新が要る）ので、コードはマイグレーションで管理する
-- （定型文・話題のような、運営が文言を直すマスタとは違う）。アイコンを足すときは、マイグレーションで1行足す。
create table public.profile_icons (
  code text primary key check (code ~ '^[a-z][a-z0-9_]{1,39}$'),
  sort_order smallint not null default 0
);

comment on table public.profile_icons is
  '選べるアイコン（イラスト）のコード。アプリに同梱する画像と対応する。profiles.icon_keyの参照先。書き込みはマイグレーションだけ。';

alter table public.profile_icons enable row level security;
-- anon・authenticated向けのポリシーと権限は作らない（deny-by-default）。画像の一覧は、アプリが持つ。

insert into public.profile_icons (code, sort_order) values
  ('sun', 1),            -- 太陽（初期のアイコン）
  ('sprout', 2),         -- 新芽
  ('little_bird', 3),    -- こ鳥
  ('yellow_flower', 4),  -- 黄色い花
  ('tulip', 5),          -- チューリップ
  ('blue_flowers', 6);   -- 青い花

-- 決まったアイコン以外の値は、空に戻す（開発中のテストデータだけ。本番にはデータがない）。
update public.profiles set icon_key = null
where icon_key is not null and icon_key not in (select code from public.profile_icons);

alter table public.profiles
  add constraint profiles_icon_key_fkey foreign key (icon_key) references public.profile_icons (code);

-- === 子どもの年齢帯：5区分 ===
-- 「いちばん下のお子さん」の年齢帯を、1つだけ選ぶ（任意）。初期版は、本人と運営者だけが読める。
update public.profiles set child_age_range = null
where child_age_range is not null
  and child_age_range not in ('age_0_1', 'age_2_3', 'age_4_6', 'elementary', 'junior_high_plus');

alter table public.profiles
  add constraint profiles_child_age_range_check
  check (child_age_range is null or child_age_range in ('age_0_1', 'age_2_3', 'age_4_6', 'elementary', 'junior_high_plus'));

comment on column public.profiles.child_age_range is
  'いちばん下のお子さんの年齢帯（任意）。age_0_1＝0〜1歳、age_2_3＝2〜3歳、age_4_6＝4〜6歳（未就学）、elementary＝小学生、junior_high_plus＝中学生以上。';
