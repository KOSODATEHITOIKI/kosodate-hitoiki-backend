-- 権限境界の検証（docs/権限表.md）。
-- Issue #10チェックリスト：未ログイン・別ユーザー・管理者の権限をDBテストで検証する。
-- 公開経路からプロフィール本文・認証情報・共感件数が漏れないことを確認する。

BEGIN;
SELECT plan(19);

-- フィクスチャ（postgresロールで作成。RLSの影響を受けない）。
INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-00000000000a'), -- user_a（投稿者）
  ('00000000-0000-0000-0000-00000000000b'), -- user_b（別ユーザー）
  ('00000000-0000-0000-0000-00000000000c'); -- 運営者

INSERT INTO public.admin_users (user_id) VALUES
  ('00000000-0000-0000-0000-00000000000c');

INSERT INTO public.profiles (id, nickname, bio) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'ユーザーA', 'user_aの自己紹介本文'),
  ('00000000-0000-0000-0000-00000000000b', 'ユーザーB', 'user_bの自己紹介本文');

INSERT INTO public.posts (id, author_id, post_type, body) VALUES
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a', 'guchi', '本文');

INSERT INTO public.reaction_types (id, label) OVERRIDING SYSTEM VALUE VALUES (1, '大変だったね');

INSERT INTO public.reactions (post_id, user_id, reaction_type_id) VALUES
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b', 1);

-- === 未ログイン（anon） ===
SET LOCAL role = 'anon';

SELECT throws_ok(
  $$select count(*) from public.profiles$$,
  '42501',
  null,
  '未ログインは profiles テーブルへ直接アクセスできない'
);

SELECT is(
  (SELECT author_nickname FROM public.public_posts WHERE id = '00000000-0000-0000-0000-0000000000f1'),
  'ユーザーA',
  '未ログインでも public_posts から投稿者のニックネームは取得できる'
);

SELECT hasnt_column('public', 'public_posts', 'author_id',
  'public_posts に投稿者の利用者ID（author_id）は含まれない');

SELECT throws_ok(
  $$select count(*) from public.public_profiles$$,
  '42501',
  null,
  '未ログインは public_profiles（利用者IDを含む）を直接参照できない'
);

SELECT hasnt_column('public', 'public_profiles', 'bio',
  'public_profiles にプロフィール本文（bio）は含まれない');

SELECT hasnt_column('public', 'public_profiles', 'child_age_range',
  'public_profiles に子どもの年齢帯（child_age_range）は含まれない');

SELECT throws_ok(
  $$select count(*) from public.comments$$,
  '42501',
  null,
  '未ログインは comments テーブルへ直接アクセスできない'
);

SELECT is(
  (SELECT count(*)::int FROM public.public_posts WHERE id = '00000000-0000-0000-0000-0000000000f1'),
  1,
  '未ログインでも public_posts から公開投稿を取得できる'
);

SELECT throws_ok(
  $$select public.get_post_reaction_count('00000000-0000-0000-0000-0000000000f1')$$,
  '42501',
  null,
  '未ログインは共感件数の関数を実行できない'
);

RESET role;

-- === 別ユーザー（authenticated、user_b） ===
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';

SELECT is(
  (SELECT count(*)::int FROM public.profiles WHERE id = '00000000-0000-0000-0000-00000000000a'),
  0,
  '別ユーザーは他人の profiles 行を直接参照できない'
);

SELECT is(
  (SELECT count(*)::int FROM public.profiles WHERE id = '00000000-0000-0000-0000-00000000000b'),
  1,
  '別ユーザーは自分自身の profiles 行は参照できる'
);

SELECT is(
  (SELECT public.get_post_reaction_count('00000000-0000-0000-0000-0000000000f1')),
  0::bigint,
  '投稿者でない authenticated ユーザーは共感件数を取得できない（0が返る）'
);

SELECT is(
  (SELECT count(*)::int FROM public.reactions WHERE post_id = '00000000-0000-0000-0000-0000000000f1'),
  1,
  '自分のリアクションは reactions テーブルから直接参照できる'
);

RESET role;

-- === 投稿者本人（authenticated、user_a） ===
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';

SELECT is(
  (SELECT public.get_post_reaction_count('00000000-0000-0000-0000-0000000000f1')),
  1::bigint,
  '投稿者本人は自分の投稿の共感件数を取得できる'
);

SELECT is(
  (SELECT count(*)::int FROM public.reactions WHERE post_id = '00000000-0000-0000-0000-0000000000f1'),
  0,
  '投稿者本人でも他者のリアクション行そのものは直接参照できない（件数はRPC経由）'
);

RESET role;

-- === 運営者（authenticated、admin_users登録済み） ===
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000c';

SELECT is(
  (SELECT count(*)::int FROM public.profiles),
  2,
  '運営者は全利用者の profiles 行を参照できる'
);

SELECT is(
  (SELECT count(*)::int FROM public.posts),
  1,
  '運営者は全投稿を参照できる'
);

SELECT is(
  (SELECT public.get_post_reaction_count('00000000-0000-0000-0000-0000000000f1')),
  1::bigint,
  '運営者は共感件数を取得できる'
);

SELECT is(
  (SELECT count(*)::int FROM public.reactions),
  0,
  '運営者でも共感の行（誰がどの共感をしたか）は直接参照できない（件数のみ）'
);

RESET role;

SELECT * FROM finish();
ROLLBACK;
