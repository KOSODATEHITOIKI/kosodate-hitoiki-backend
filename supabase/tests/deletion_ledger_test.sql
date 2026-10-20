-- 削除の台帳と、復元後の再削除（replay_deletion_ledger）の検証（Issue #21）。
-- 「バックアップから復元されて、削除済みのデータが復活した」状態を、削除のあとに同じ行を入れ直して模擬する。

BEGIN;
SELECT plan(27);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000b1'), -- 投稿を削除する人
  ('00000000-0000-0000-0000-0000000000b2'), -- 退会する人
  ('00000000-0000-0000-0000-0000000000b3'); -- 何もしない人
INSERT INTO public.profiles (id, nickname) VALUES
  ('00000000-0000-0000-0000-0000000000b1', 'さくじょにん'),
  ('00000000-0000-0000-0000-0000000000b2', 'たいかいにん'),
  ('00000000-0000-0000-0000-0000000000b3', 'のこるにん');
INSERT INTO public.notification_settings (user_id) SELECT id FROM auth.users;

INSERT INTO public.posts (id, author_id, post_type, body, reaction_mode, comment_acceptance) VALUES
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', 'soudan', '消す投稿', 'want_comments', 'open'),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b3', 'soudan', '残る投稿', 'want_comments', 'open'),
  ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000b2', 'guchi', '退会する人の投稿', 'quiet_support', null);
INSERT INTO public.comments (id, post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b1', '消すコメント'),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b3', '残るコメント');

SELECT is((SELECT count(*)::int FROM public.deletion_ledger), 0, '何も削除していなければ、台帳は空');

-- === 台帳への記録 ===
DELETE FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000c1';
SELECT is((SELECT count(*)::int FROM public.deletion_ledger WHERE kind = 'post' AND target_id = '00000000-0000-0000-0000-0000000000c1'), 1,
  '投稿の削除が台帳に記録される');

UPDATE public.comments SET deleted_at = now() WHERE id = '00000000-0000-0000-0000-0000000000d1';
SELECT is((SELECT count(*)::int FROM public.deletion_ledger WHERE kind = 'comment' AND target_id = '00000000-0000-0000-0000-0000000000d1'), 1,
  'コメントの削除（本文が消える）が台帳に記録される');
SELECT is((SELECT body FROM public.comments WHERE id = '00000000-0000-0000-0000-0000000000d1'), NULL, '削除したコメントの本文は消えている');

SELECT public.withdraw_account('00000000-0000-0000-0000-0000000000b2');
SELECT is((SELECT count(*)::int FROM public.deletion_ledger WHERE kind = 'user' AND target_id = '00000000-0000-0000-0000-0000000000b2'), 1,
  '退会が台帳に記録される');
SELECT is((SELECT count(*)::int FROM public.deletion_ledger WHERE kind = 'post' AND target_id = '00000000-0000-0000-0000-0000000000c3'), 1,
  '退会でカスケード削除された投稿も記録される');

SELECT is(
  (SELECT count(*)::int FROM public.deletion_ledger WHERE target_id IN ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000d2')),
  0, '残るものは記録されない');

-- 台帳は、IDと時刻だけを持つ（本文・ニックネームなどを持たない）
SELECT is(
  (SELECT array_agg(column_name::text ORDER BY column_name) FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'deletion_ledger'),
  ARRAY['deleted_at', 'kind', 'target_id'], '台帳が持つのは、種類・ID・時刻だけ');

-- === 復元の模擬：バックアップが取られた時点の状態に戻る（削除済みのデータが復活する） ===
INSERT INTO auth.users (id) VALUES ('00000000-0000-0000-0000-0000000000b2') ON CONFLICT DO NOTHING;
INSERT INTO public.profiles (id, nickname) VALUES ('00000000-0000-0000-0000-0000000000b2', 'たいかいにん');
INSERT INTO public.posts (id, author_id, post_type, body, reaction_mode, comment_acceptance) VALUES
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', 'soudan', '消したはずの投稿', 'want_comments', 'open'),
  ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000b2', 'guchi', '退会したはずの人の投稿', 'quiet_support', null);
UPDATE public.comments SET deleted_at = NULL, body = '消したはずのコメント' WHERE id = '00000000-0000-0000-0000-0000000000d1';
-- 復活した投稿へのコメントと、他の人の「非表示」も戻る
INSERT INTO public.comments (id, post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b3', '復活した投稿へのコメント');
INSERT INTO public.hidden_items (user_id, target_type, target_id) VALUES
  ('00000000-0000-0000-0000-0000000000b3', 'post', '00000000-0000-0000-0000-0000000000c1');

SELECT is((SELECT count(*)::int FROM public.posts WHERE id IN ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c3')), 2,
  '（模擬）復元で、削除済みの投稿が復活した');

-- === 再削除 ===
SELECT is(public.replay_deletion_ledger() ->> 'users', '1', '台帳にあるアカウントが、再び削除される');
SELECT is((SELECT count(*)::int FROM auth.users WHERE id = '00000000-0000-0000-0000-0000000000b2'), 0, '退会した人は復活しない');
SELECT is((SELECT count(*)::int FROM public.profiles WHERE id = '00000000-0000-0000-0000-0000000000b2'), 0, '退会した人のプロフィールも消える');
SELECT is((SELECT count(*)::int FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000c3'), 0, '退会した人の投稿は復活しない');
SELECT is((SELECT count(*)::int FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000c1'), 0, '削除した投稿は復活しない');
SELECT is((SELECT count(*)::int FROM public.comments WHERE id = '00000000-0000-0000-0000-0000000000d3'), 0, '削除した投稿についていたコメントも消える');
SELECT is((SELECT body FROM public.comments WHERE id = '00000000-0000-0000-0000-0000000000d1'), NULL, '削除したコメントの本文は復活しない');
SELECT ok((SELECT deleted_at IS NOT NULL FROM public.comments WHERE id = '00000000-0000-0000-0000-0000000000d1'), '削除したコメントは削除済みに戻る');
SELECT is((SELECT count(*)::int FROM public.hidden_items WHERE target_id = '00000000-0000-0000-0000-0000000000c1'), 0,
  '復活した「非表示」の残骸も消える');

-- 残るものには触れない
SELECT is((SELECT count(*)::int FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000c2'), 1, '残る投稿は残る');
SELECT is((SELECT body FROM public.comments WHERE id = '00000000-0000-0000-0000-0000000000d2'), '残るコメント', '残るコメントは残る');
SELECT is((SELECT count(*)::int FROM public.profiles WHERE id = '00000000-0000-0000-0000-0000000000b3'), 1, '残る人は残る');

-- 何度実行しても同じ（冪等）
SELECT is(public.replay_deletion_ledger(), '{"users": 0, "posts": 0, "comments": 0, "hidden_items": 0}'::jsonb, '2回目は何も変えない');

-- === 別の場所に書き出した台帳の取り込み ===
SELECT is(public.import_deletion_ledger('[{"kind":"post","target_id":"00000000-0000-0000-0000-0000000000e1","deleted_at":"2026-10-01T00:00:00Z"}]'::jsonb), 1,
  '書き出した台帳を取り込める');
SELECT is(public.import_deletion_ledger('[{"kind":"post","target_id":"00000000-0000-0000-0000-0000000000e1","deleted_at":"2026-10-01T00:00:00Z"}]'::jsonb), 0,
  '同じ行の取り込みは重複しない');

-- === 保持期限（35日） ===
UPDATE public.deletion_ledger SET deleted_at = now() - interval '36 days' WHERE target_id = '00000000-0000-0000-0000-0000000000e1';
SELECT public.purge_expired_records();
SELECT is((SELECT count(*)::int FROM public.deletion_ledger WHERE target_id = '00000000-0000-0000-0000-0000000000e1'), 0, '35日を過ぎた台帳は削除される');

-- === 利用者からは読めない・呼べない ===
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT count(*) FROM public.deletion_ledger$$, '42501', NULL, '利用者は台帳を読めない');
SELECT throws_ok($$SELECT public.replay_deletion_ledger()$$, '42501', NULL, '利用者は再削除を実行できない');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
