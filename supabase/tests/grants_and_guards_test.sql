-- 権限付与とRLS強化の検証（PR #28レビュー指摘）。
-- auto_expose_new_tables = false 前提で、anon・authenticatedが必要最小限の権限だけを持つこと、
-- admin_usersのポリシーが再帰しないこと、一時非表示投稿のコメント・共感が制限されることを確認する。

BEGIN;
SELECT plan(10);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-00000000000a'), -- user_a（投稿者）
  ('00000000-0000-0000-0000-00000000000b'), -- user_b（別ユーザー）
  ('00000000-0000-0000-0000-00000000000c'), -- 運営者
  ('00000000-0000-0000-0000-00000000000d'); -- user_d（利用停止中）

INSERT INTO public.admin_users (user_id) VALUES
  ('00000000-0000-0000-0000-00000000000c');

INSERT INTO public.posts (id, author_id, post_type, body, hidden_at) VALUES
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a', 'guchi', '公開投稿', null),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000000a', 'guchi', '一時非表示の投稿', now());

-- コメント投稿で投稿者（user_a）へ通知が作られる。
INSERT INTO public.comments (id, post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b', '公開投稿へのコメント'),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000000b', '非表示投稿へのコメント');

INSERT INTO public.reaction_types (id, label) OVERRIDING SYSTEM VALUE VALUES (1, '大変だったね');

INSERT INTO public.account_restrictions (user_id, stage, ends_at, created_by) VALUES
  ('00000000-0000-0000-0000-00000000000d', 1, now() + interval '7 days', '00000000-0000-0000-0000-00000000000c');

-- === 未ログイン（anon） ===
SET LOCAL role = 'anon';

SELECT is(
  (SELECT public.post_comment_count('00000000-0000-0000-0000-0000000000f1')),
  1::bigint,
  '公開投稿の公開コメント件数を未ログインでも取得できる'
);

SELECT is(
  (SELECT public.post_comment_count('00000000-0000-0000-0000-0000000000f2')),
  0::bigint,
  '一時非表示の投稿のコメントは件数に含めない'
);

SELECT throws_ok(
  $$select count(*) from public.reactions$$,
  '42501',
  null,
  '未ログインは reactions に権限を持たない'
);

RESET role;

-- === 別ユーザー（authenticated、user_b） ===
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';

SELECT is(
  (SELECT count(*)::int FROM public.admin_users),
  0,
  '一般利用者は admin_users を参照しても再帰せず0件になる'
);

SELECT is(
  (SELECT count(*)::int FROM public.comments WHERE id = '00000000-0000-0000-0000-0000000000c1'),
  1,
  '公開投稿のコメントはログイン済み利用者が参照できる'
);

SELECT is(
  (SELECT count(*)::int FROM public.comments WHERE id = '00000000-0000-0000-0000-0000000000c2'),
  0,
  '一時非表示の投稿のコメントは一般利用者から隠れる'
);

-- 共感はDB関数（service_role専用）からのみ書き込む。直接の書き込みはできない（reactions_saved_test.sqlで詳細を検証）。
SELECT throws_ok(
  $$insert into public.reactions (post_id, user_id, reaction_type_id)
    values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b', 1)$$,
  '42501',
  null,
  '共感を直接書き込めない（ブロック・利用停止・非表示の確認を迂回できない）'
);

RESET role;

-- === 投稿者本人（authenticated、user_a） ===
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';

SELECT lives_ok(
  $$update public.notifications set is_read = true$$,
  '通知の既読フラグは更新できる'
);

SELECT throws_ok(
  $$update public.notifications set user_id = '00000000-0000-0000-0000-00000000000b'$$,
  '42501',
  null,
  '通知の既読フラグ以外の列は更新できない'
);

RESET role;

-- === 運営者（authenticated） ===
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000c';

SELECT is(
  (SELECT count(*)::int FROM public.admin_users),
  1,
  '運営者は admin_users を参照できる'
);

RESET role;

SELECT * FROM finish();
ROLLBACK;
