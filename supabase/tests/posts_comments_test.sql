-- 投稿・コメント・返信のDB関数の検証（Issue #13）。
-- 受付終了とコメント保存の同時実行の競合は、pgTAPでは検証できないため
-- supabase/tests/concurrency/run.sh で検証する。

BEGIN;
SELECT plan(51);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000a1'), -- 投稿者
  ('00000000-0000-0000-0000-0000000000a2'), -- コメントする人
  ('00000000-0000-0000-0000-0000000000a3'), -- 第三者
  ('00000000-0000-0000-0000-0000000000a4'), -- 利用停止中
  ('00000000-0000-0000-0000-0000000000a5'); -- プロフィール未作成

INSERT INTO public.profiles (id, nickname) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'とうこうしゃ'),
  ('00000000-0000-0000-0000-0000000000a2', 'こめんと'),
  ('00000000-0000-0000-0000-0000000000a3', 'だいさんしゃ'),
  ('00000000-0000-0000-0000-0000000000a4', 'ていしちゅう');

INSERT INTO public.account_restrictions (user_id, stage, ends_at, created_by) VALUES
  ('00000000-0000-0000-0000-0000000000a4', 1, now() + interval '7 days',
   '00000000-0000-0000-0000-0000000000a1');

-- === 投稿の作成 ===
CREATE TEMP TABLE ids (name text primary key, id uuid);

INSERT INTO ids SELECT 'post_quiet', (public.create_post(
  '00000000-0000-0000-0000-0000000000a1', 'guchi', null, '今日は大変だった', 'quiet_support', null
) ->> 'id')::uuid;

INSERT INTO ids SELECT 'post_open', (public.create_post(
  '00000000-0000-0000-0000-0000000000a1', 'soudan', null, '相談です', 'want_comments', null
) ->> 'id')::uuid;

SELECT is(
  (SELECT comment_acceptance FROM public.posts WHERE id = (SELECT id FROM ids WHERE name = 'post_quiet')),
  NULL,
  '「ただ聞いてほしい」の投稿は受付状態を持たない'
);

SELECT is(
  (SELECT comment_acceptance FROM public.posts WHERE id = (SELECT id FROM ids WHERE name = 'post_open')),
  'open',
  '「話を聞きたい」の投稿は受付中で始まる'
);

SELECT throws_ok(
  $$select public.create_post('00000000-0000-0000-0000-0000000000a5', 'guchi', null, '本文', 'quiet_support', null)$$,
  'P0001', 'PROFILE_REQUIRED',
  'プロフィール未作成の利用者は投稿できない'
);

SELECT throws_ok(
  $$select public.create_post('00000000-0000-0000-0000-0000000000a4', 'guchi', null, '本文', 'quiet_support', null)$$,
  'P0001', 'RESTRICTED',
  '利用停止中は投稿できない'
);

SELECT throws_ok(
  $$select public.create_post('00000000-0000-0000-0000-0000000000a1', 'guchi', 999::smallint, '本文', 'quiet_support', null)$$,
  'P0001', 'VALIDATION_FAILED',
  '存在しない話題は指定できない'
);

-- 再送（Idempotency-Key）：同じキーは最初の結果を返し、投稿を重複させない
SELECT is(
  (public.create_post('00000000-0000-0000-0000-0000000000a1', 'guchi', null, '再送テスト', 'quiet_support', 'key-1') ->> 'id')
  = (public.create_post('00000000-0000-0000-0000-0000000000a1', 'guchi', null, '再送テスト', 'quiet_support', 'key-1') ->> 'id'),
  true,
  '同じIdempotency-Keyの再送は、最初と同じ投稿IDを返す'
);

SELECT is(
  (SELECT count(*)::int FROM public.posts WHERE body = '再送テスト'),
  1,
  '再送しても投稿は1件だけ'
);

SELECT is(
  (public.create_post('00000000-0000-0000-0000-0000000000a2', 'guchi', null, '別の利用者', 'quiet_support', 'key-1') ->> 'id')
  <> (public.create_post('00000000-0000-0000-0000-0000000000a1', 'guchi', null, '再送テスト', 'quiet_support', 'key-1') ->> 'id'),
  true,
  '同じキーでも、利用者が違えば別の投稿になる'
);

-- === 投稿の編集 ===
SELECT is(
  (SELECT edited_at FROM public.posts WHERE id = (SELECT id FROM ids WHERE name = 'post_quiet')),
  NULL,
  '作成直後の投稿は「編集済み」ではない'
);

SELECT lives_ok(
  $$select public.update_post_body('00000000-0000-0000-0000-0000000000a1', (select id from ids where name = 'post_quiet'), '今日は大変だった')$$,
  '本文が同じ内容での編集は成功する'
);

SELECT is(
  (SELECT edited_at FROM public.posts WHERE id = (SELECT id FROM ids WHERE name = 'post_quiet')),
  NULL,
  '本文が変わらない編集では「編集済み」にならない'
);

SELECT lives_ok(
  $$select public.update_post_body('00000000-0000-0000-0000-0000000000a1', (select id from ids where name = 'post_quiet'), '書き直した')$$,
  '本人は本文を編集できる'
);

SELECT isnt(
  (SELECT edited_at FROM public.posts WHERE id = (SELECT id FROM ids WHERE name = 'post_quiet')),
  NULL,
  '本文が変わると「編集済み」になる'
);

SELECT throws_ok(
  $$select public.update_post_body('00000000-0000-0000-0000-0000000000a2', (select id from ids where name = 'post_quiet'), '乗っ取り')$$,
  'P0001', 'FORBIDDEN',
  '他人は投稿を編集できない'
);

SELECT throws_ok(
  $$select public.update_post_body('00000000-0000-0000-0000-0000000000a1', gen_random_uuid(), '本文')$$,
  'P0001', 'NOT_FOUND',
  '存在しない投稿は編集できない'
);

-- === 反応モード・受付状態 ===
SELECT is(
  (public.set_post_reaction_mode('00000000-0000-0000-0000-0000000000a1', (SELECT id FROM ids WHERE name = 'post_quiet'), 'want_comments', null) ->> 'comment_acceptance'),
  'open',
  '「ただ聞いてほしい」→「話を聞きたい」へ変更すると受付中になる'
);

SELECT is(
  (public.set_post_reaction_mode('00000000-0000-0000-0000-0000000000a1', (SELECT id FROM ids WHERE name = 'post_quiet'), 'want_comments', 'closed') ->> 'comment_acceptance'),
  'closed',
  '受付を終了できる'
);

SELECT is(
  (public.set_post_reaction_mode('00000000-0000-0000-0000-0000000000a1', (SELECT id FROM ids WHERE name = 'post_quiet'), 'want_comments', 'open') ->> 'comment_acceptance'),
  'open',
  '受付を再開できる'
);

SELECT is(
  (public.set_post_reaction_mode('00000000-0000-0000-0000-0000000000a1', (SELECT id FROM ids WHERE name = 'post_quiet'), 'quiet_support', null) ->> 'reaction_mode'),
  'quiet_support',
  '「話を聞きたい」→「ただ聞いてほしい」への逆方向の変更もできる'
);

SELECT is(
  (SELECT comment_acceptance FROM public.posts WHERE id = (SELECT id FROM ids WHERE name = 'post_quiet')),
  NULL,
  '逆方向に戻すと受付状態はなくなる'
);

SELECT throws_ok(
  $$select public.set_post_reaction_mode('00000000-0000-0000-0000-0000000000a1', (select id from ids where name = 'post_quiet'), 'quiet_support', 'open')$$,
  'P0001', 'VALIDATION_FAILED',
  '「ただ聞いてほしい」に受付状態は指定できない'
);

SELECT throws_ok(
  $$select public.set_post_reaction_mode('00000000-0000-0000-0000-0000000000a2', (select id from ids where name = 'post_open'), 'quiet_support', null)$$,
  'P0001', 'FORBIDDEN',
  '他人は反応モードを変更できない'
);

-- === コメント・返信 ===
-- 「ただ聞いてほしい」には自由コメントできない
SELECT throws_ok(
  $$select public.create_comment('00000000-0000-0000-0000-0000000000a2', (select id from ids where name = 'post_quiet'), null, 'こんにちは', null)$$,
  'P0001', 'COMMENTS_CLOSED',
  '「ただ聞いてほしい」の投稿にはコメントできない'
);

INSERT INTO ids SELECT 'c1', (public.create_comment(
  '00000000-0000-0000-0000-0000000000a2', (SELECT id FROM ids WHERE name = 'post_open'), null, 'わかります', null
) ->> 'id')::uuid;

SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE user_id = '00000000-0000-0000-0000-0000000000a1' AND notification_type = 'comment'),
  1,
  'コメントすると投稿者へ通知が作られる'
);

SELECT throws_ok(
  $$select public.create_comment('00000000-0000-0000-0000-0000000000a5', (select id from ids where name = 'post_open'), null, 'こんにちは', null)$$,
  'P0001', 'PROFILE_REQUIRED',
  'プロフィール未作成の利用者はコメントできない'
);

SELECT throws_ok(
  $$select public.create_comment('00000000-0000-0000-0000-0000000000a4', (select id from ids where name = 'post_open'), null, 'こんにちは', null)$$,
  'P0001', 'RESTRICTED',
  '利用停止中はコメントできない'
);

SELECT throws_ok(
  $$select public.create_comment('00000000-0000-0000-0000-0000000000a2', gen_random_uuid(), null, 'こんにちは', null)$$,
  'P0001', 'NOT_FOUND',
  '存在しない投稿にはコメントできない'
);

-- 返信
INSERT INTO ids SELECT 'r1', (public.create_comment(
  '00000000-0000-0000-0000-0000000000a1', (SELECT id FROM ids WHERE name = 'post_open'), (SELECT id FROM ids WHERE name = 'c1'), 'ありがとう', null
) ->> 'id')::uuid;

SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE user_id = '00000000-0000-0000-0000-0000000000a2' AND notification_type = 'reply'),
  1,
  '返信すると、返信先コメントの投稿者へ通知が作られる'
);

SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE user_id = '00000000-0000-0000-0000-0000000000a1' AND notification_type = 'reply'),
  0,
  '自分への返信（自分自身）には通知しない'
);

SELECT throws_ok(
  $$select public.create_comment('00000000-0000-0000-0000-0000000000a2', (select id from ids where name = 'post_open'), (select id from ids where name = 'r1'), '返信への返信', null)$$,
  'P0001', '返信への返信はできません',
  '返信への返信は拒否される（1段階のみ）'
);

SELECT throws_ok(
  $$select public.create_comment('00000000-0000-0000-0000-0000000000a2', (select id from ids where name = 'post_open'), gen_random_uuid(), 'こんにちは', null)$$,
  'P0001', 'VALIDATION_FAILED',
  '存在しない親コメントは指定できない'
);

-- 別の投稿のコメントを親にはできない
INSERT INTO ids SELECT 'post_open2', (public.create_post(
  '00000000-0000-0000-0000-0000000000a1', 'soudan', null, '別の相談', 'want_comments', null
) ->> 'id')::uuid;

SELECT throws_ok(
  $$select public.create_comment('00000000-0000-0000-0000-0000000000a2', (select id from ids where name = 'post_open2'), (select id from ids where name = 'c1'), 'こんにちは', null)$$,
  'P0001', 'VALIDATION_FAILED',
  '別の投稿のコメントを親にはできない'
);

-- 再送
SELECT is(
  (public.create_comment('00000000-0000-0000-0000-0000000000a3', (SELECT id FROM ids WHERE name = 'post_open'), null, '再送', 'ckey-1') ->> 'id')
  = (public.create_comment('00000000-0000-0000-0000-0000000000a3', (SELECT id FROM ids WHERE name = 'post_open'), null, '再送', 'ckey-1') ->> 'id'),
  true,
  '同じIdempotency-Keyのコメント再送は、最初と同じIDを返す'
);

SELECT is(
  (SELECT count(*)::int FROM public.comments WHERE body = '再送'),
  1,
  '再送してもコメントは1件だけ'
);

-- ブロック
INSERT INTO public.blocks (blocker_id, blocked_id) VALUES
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a3');

SELECT throws_ok(
  $$select public.create_comment('00000000-0000-0000-0000-0000000000a3', (select id from ids where name = 'post_open'), null, 'ブロックされた', null)$$,
  'P0001', 'BLOCKED',
  '投稿者にブロックされた人はコメントできない'
);

INSERT INTO public.blocks (blocker_id, blocked_id) VALUES
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a3');

SELECT throws_ok(
  $$select public.create_comment('00000000-0000-0000-0000-0000000000a3', (select id from ids where name = 'post_open2'), (select id from ids where name = 'c1'), 'ブロックされた', null)$$,
  'P0001', 'BLOCKED',
  '返信先のコメント投稿者にブロックされた人は返信できない'
);

-- === 受付終了 ===
SELECT public.set_post_reaction_mode('00000000-0000-0000-0000-0000000000a1', (SELECT id FROM ids WHERE name = 'post_open'), 'want_comments', 'closed');

SELECT throws_ok(
  $$select public.create_comment('00000000-0000-0000-0000-0000000000a2', (select id from ids where name = 'post_open'), null, '遅れたコメント', null)$$,
  'P0001', 'COMMENTS_CLOSED',
  '受付終了後は新規コメントを保存しない'
);

SELECT throws_ok(
  $$select public.create_comment('00000000-0000-0000-0000-0000000000a2', (select id from ids where name = 'post_open'), (select id from ids where name = 'c1'), '遅れた返信', null)$$,
  'P0001', 'COMMENTS_CLOSED',
  '受付終了後は新規の返信も保存しない'
);

-- === コメントの編集 ===
SELECT lives_ok(
  $$select public.update_comment_body('00000000-0000-0000-0000-0000000000a2', (select id from ids where name = 'c1'), '書き直しました')$$,
  '受付終了後も、本人は既存コメントを編集できる'
);

SELECT isnt(
  (SELECT edited_at FROM public.comments WHERE id = (SELECT id FROM ids WHERE name = 'c1')),
  NULL,
  'コメントも本文が変わると「編集済み」になる'
);

SELECT throws_ok(
  $$select public.update_comment_body('00000000-0000-0000-0000-0000000000a3', (select id from ids where name = 'c1'), '乗っ取り')$$,
  'P0001', 'FORBIDDEN',
  '他人はコメントを編集できない'
);

-- === コメントの削除（ソフト削除。返信は残る） ===
SELECT lives_ok(
  $$select public.delete_comment('00000000-0000-0000-0000-0000000000a2', (select id from ids where name = 'c1'))$$,
  '本人はコメントを削除できる'
);

SELECT is(
  (SELECT body FROM public.comments WHERE id = (SELECT id FROM ids WHERE name = 'c1')),
  NULL,
  '削除したコメントの本文は消える'
);

SELECT is(
  (SELECT count(*)::int FROM public.comments WHERE id = (SELECT id FROM ids WHERE name = 'r1')),
  1,
  '親コメントを削除しても、返信は残る'
);

SELECT throws_ok(
  $$select public.delete_comment('00000000-0000-0000-0000-0000000000a2', (select id from ids where name = 'c1'))$$,
  'P0001', 'NOT_FOUND',
  '削除済みのコメントは再度削除できない'
);

SELECT throws_ok(
  $$select public.update_comment_body('00000000-0000-0000-0000-0000000000a2', (select id from ids where name = 'c1'), '復活')$$,
  'P0001', 'NOT_FOUND',
  '削除済みのコメントは編集できない'
);

-- 受付を再開しても、削除済みの親コメントには返信できない
SELECT public.set_post_reaction_mode('00000000-0000-0000-0000-0000000000a1', (SELECT id FROM ids WHERE name = 'post_open'), 'want_comments', 'open');

SELECT throws_ok(
  $$select public.create_comment('00000000-0000-0000-0000-0000000000a2', (select id from ids where name = 'post_open'), (select id from ids where name = 'c1'), '削除済みへの返信', null)$$,
  'P0001', 'VALIDATION_FAILED',
  '削除済みの親コメントには新たに返信できない'
);

-- === 投稿の削除 ===
INSERT INTO public.hidden_items (user_id, target_type, target_id) VALUES
  ('00000000-0000-0000-0000-0000000000a3', 'post', (SELECT id FROM ids WHERE name = 'post_open')),
  ('00000000-0000-0000-0000-0000000000a3', 'comment', (SELECT id FROM ids WHERE name = 'r1'));

SELECT throws_ok(
  $$select public.delete_post('00000000-0000-0000-0000-0000000000a2', (select id from ids where name = 'post_open'))$$,
  'P0001', 'FORBIDDEN',
  '他人は投稿を削除できない'
);

SELECT lives_ok(
  $$select public.delete_post('00000000-0000-0000-0000-0000000000a1', (select id from ids where name = 'post_open'))$$,
  '本人は投稿を削除できる'
);

SELECT is(
  (SELECT count(*)::int FROM public.comments WHERE post_id = (SELECT id FROM ids WHERE name = 'post_open')),
  0,
  '投稿を削除すると、コメント・返信も消える'
);

SELECT is(
  (SELECT count(*)::int FROM public.hidden_items WHERE user_id = '00000000-0000-0000-0000-0000000000a3'),
  0,
  '投稿を削除すると、本人だけの非表示の残骸（論理参照）も消える'
);

SELECT * FROM finish();
ROLLBACK;
