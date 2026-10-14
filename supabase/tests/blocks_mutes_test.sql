-- 自分だけの非表示・ブロック・話題／言葉ミュートの検証（Issue #14）。
-- 設定は本人限定のRLSで直接操作し、投稿・コメント・通知の取得に反映される。

BEGIN;
SELECT plan(43);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000a1'), -- A：閲覧者（ブロックする側）
  ('00000000-0000-0000-0000-0000000000a2'), -- B：ブロックされる側
  ('00000000-0000-0000-0000-0000000000a3'); -- C：第三者

INSERT INTO public.profiles (id, nickname) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'えー'),
  ('00000000-0000-0000-0000-0000000000a2', 'びー'),
  ('00000000-0000-0000-0000-0000000000a3', 'しー');

INSERT INTO public.topics (id, label) OVERRIDING SYSTEM VALUE VALUES (1, '睡眠'), (2, '食事');

-- 投稿：Bの投稿（話題1）、Cの投稿（話題2）、Aの投稿（話題なし・コメント受付中）
INSERT INTO public.posts (id, author_id, post_type, topic_id, body, reaction_mode, comment_acceptance) VALUES
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a2', 'guchi', 1, 'Bの投稿です', 'quiet_support', null),
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000a3', 'guchi', 2, 'Cの投稿です', 'quiet_support', null),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', 'soudan', null, 'Aの相談です', 'want_comments', 'open');

-- コメント：B・Cが、Aの投稿にコメント。AがBへ返信。
INSERT INTO public.comments (id, post_id, author_id, parent_comment_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a2', null, 'Bのコメント'),
  ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a3', null, 'Cのコメント');

-- Bのコメントで、Aへ通知が作られている（トリガー）
SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE user_id = '00000000-0000-0000-0000-0000000000a1'),
  2,
  '（前提）B・Cのコメントで、Aへ通知が2件作られている'
);

-- === ブロックする前：Aから見える ===
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';

SELECT is(
  (SELECT count(*)::int FROM public.feed_posts WHERE id IN
    ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b3')),
  2,
  'ブロック前は、Bの投稿もCの投稿も一覧に出る'
);

SELECT is(
  (SELECT count(*)::int FROM public.member_comments WHERE post_id = '00000000-0000-0000-0000-0000000000b1'),
  2,
  'ブロック前は、Bのコメントもほかのコメントも見える'
);

-- === ブロック ===
SELECT lives_ok(
  $$insert into public.blocks (blocker_id, blocked_id) values
    ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2')$$,
  'AはBをブロックできる（本人限定のRLS）'
);

SELECT throws_ok(
  $$insert into public.blocks (blocker_id, blocked_id) values
    ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2')$$,
  '23505', null,
  '同じ相手を重複してブロックすると一意制約で拒否される'
);

SELECT throws_ok(
  $$insert into public.blocks (blocker_id, blocked_id) values
    ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')$$,
  '23514', null,
  '自分自身はブロックできない'
);

SELECT throws_ok(
  $$insert into public.blocks (blocker_id, blocked_id) values
    ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a2')$$,
  '42501', null,
  '他人の名義でブロックを作ることはできない'
);

SELECT is(
  (SELECT count(*)::int FROM public.feed_posts WHERE id = '00000000-0000-0000-0000-0000000000b2'),
  0,
  'ブロックしたBの投稿は一覧に出ない'
);

SELECT is(
  (SELECT count(*)::int FROM public.member_posts WHERE id = '00000000-0000-0000-0000-0000000000b2'),
  0,
  'ブロックしたBの投稿は詳細（ID指定）でも出ない'
);

SELECT is(
  (SELECT count(*)::int FROM public.feed_posts WHERE id = '00000000-0000-0000-0000-0000000000b3'),
  1,
  'ブロックしていないCの投稿は出る'
);

SELECT is(
  (SELECT count(*)::int FROM public.member_comments WHERE id = '00000000-0000-0000-0000-0000000000c2'),
  0,
  'ブロックしたBのコメントは出ない'
);

SELECT is(
  (SELECT count(*)::int FROM public.member_comments WHERE id = '00000000-0000-0000-0000-0000000000c3'),
  1,
  'Cのコメントは出る'
);

SELECT is(
  (SELECT count(*)::int FROM public.notifications),
  1,
  'ブロックしたBが起こした通知は表示されない'
);

RESET role;

-- === ブロックされたB側：相手に知らせない・公開投稿は隠れない ===
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a2';

SELECT is(
  (SELECT count(*)::int FROM public.blocks),
  0,
  'ブロックされたBは、ブロックされている事実を参照できない'
);

SELECT is(
  (SELECT count(*)::int FROM public.feed_posts WHERE id = '00000000-0000-0000-0000-0000000000b1'),
  1,
  'ブロックされたBにも、Aの公開投稿は見える（公開のため完全には隠さない）'
);

SELECT is(
  (SELECT count(*)::int FROM public.notifications),
  0,
  'ブロックされたBには、ブロックの通知は作られない'
);

RESET role;

SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE user_id = '00000000-0000-0000-0000-0000000000a2'),
  0,
  'ブロックの操作でBへ通知は作られない（テーブルにも存在しない）'
);

-- 匿名は、公開投稿の取得経路にブロックの影響を受けない（個人設定はない）
SET LOCAL role = 'anon';
SELECT is(
  (SELECT count(*)::int FROM public.public_posts WHERE id = '00000000-0000-0000-0000-0000000000b2'),
  1,
  '未ログインの公開一覧には、ブロックの影響がない（公開投稿のまま）'
);

SELECT throws_ok(
  $$select count(*) from public.feed_posts$$,
  '42501', null,
  '未ログインは feed_posts を参照できない'
);

SELECT throws_ok(
  $$select count(*) from public.member_posts$$,
  '42501', null,
  '未ログインは member_posts を参照できない'
);

SELECT throws_ok(
  $$select count(*) from public.blocks$$,
  '42501', null,
  '未ログインは blocks を参照できない'
);
RESET role;

-- === ブロック解除 ===
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';

SELECT lives_ok(
  $$delete from public.blocks where blocked_id = '00000000-0000-0000-0000-0000000000a2'$$,
  'ブロックを解除できる'
);

SELECT lives_ok(
  $$delete from public.blocks where blocked_id = '00000000-0000-0000-0000-0000000000a2'$$,
  '解除済みの相手を重複して解除しても、エラーにならない（冪等）'
);

SELECT is(
  (SELECT count(*)::int FROM public.feed_posts WHERE id = '00000000-0000-0000-0000-0000000000b2'),
  1,
  '解除すると、Bの投稿が再び一覧に出る'
);

-- === 自分だけの非表示 ===
SELECT lives_ok(
  $$insert into public.hidden_items (user_id, target_type, target_id) values
    ('00000000-0000-0000-0000-0000000000a1', 'post', '00000000-0000-0000-0000-0000000000b3'),
    ('00000000-0000-0000-0000-0000000000a1', 'comment', '00000000-0000-0000-0000-0000000000c3')$$,
  '投稿・コメントを自分だけ非表示にできる'
);

SELECT is(
  (SELECT count(*)::int FROM public.feed_posts WHERE id = '00000000-0000-0000-0000-0000000000b3'),
  0,
  '自分だけ非表示にした投稿は、一覧にも出ない'
);

SELECT is(
  (SELECT count(*)::int FROM public.member_posts WHERE id = '00000000-0000-0000-0000-0000000000b3'),
  0,
  '自分だけ非表示にした投稿は、詳細にも出ない'
);

SELECT is(
  (SELECT count(*)::int FROM public.member_comments WHERE id = '00000000-0000-0000-0000-0000000000c3'),
  0,
  '自分だけ非表示にしたコメントは出ない'
);

RESET role;

SELECT is(
  (SELECT count(*)::int FROM public.public_posts WHERE id = '00000000-0000-0000-0000-0000000000b3'),
  1,
  '自分だけの非表示は、ほかの人（未ログイン含む）には影響しない'
);

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a3';
SELECT is(
  (SELECT count(*)::int FROM public.member_comments WHERE id = '00000000-0000-0000-0000-0000000000c3'),
  1,
  '自分だけの非表示は、別のログイン済み利用者には影響しない'
);
RESET role;

-- === 話題ミュート ===
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';

SELECT lives_ok(
  $$insert into public.muted_topics (user_id, topic_id) values ('00000000-0000-0000-0000-0000000000a1', 1)$$,
  '話題をミュートできる'
);

SELECT is(
  (SELECT count(*)::int FROM public.feed_posts WHERE id = '00000000-0000-0000-0000-0000000000b2'),
  0,
  'ミュートした話題の投稿は、一覧・検索の元には出ない'
);

SELECT is(
  (SELECT count(*)::int FROM public.member_posts WHERE id = '00000000-0000-0000-0000-0000000000b2'),
  1,
  'ミュートは詳細（ID指定）には適用しない（通知からの参照などを妨げない）'
);

SELECT is(
  (SELECT count(*)::int FROM public.feed_posts WHERE topic_id IS NULL),
  1,
  '話題のない投稿は、話題ミュートの影響を受けない'
);

-- === 言葉ミュート ===
SELECT lives_ok(
  $$insert into public.muted_words (user_id, word) values ('00000000-0000-0000-0000-0000000000a1', '  ＡＢＣ  ')$$,
  '言葉をミュートできる（前後の空白は除いて保存）'
);

SELECT is(
  (SELECT word FROM public.muted_words),
  'ＡＢＣ',
  'ミュートする言葉は前後の空白を除いて保存される'
);

SELECT throws_ok(
  $$insert into public.muted_words (user_id, word) values ('00000000-0000-0000-0000-0000000000a1', 'abc')$$,
  '23505', null,
  '全角・半角、大文字・小文字が違うだけの言葉は重複として拒否される'
);

SELECT throws_ok(
  $$insert into public.muted_words (user_id, word) values ('00000000-0000-0000-0000-0000000000a1', '   ')$$,
  '23514', null,
  '空白だけの言葉はミュートできない'
);

RESET role;

INSERT INTO public.posts (id, author_id, post_type, body) VALUES
  ('00000000-0000-0000-0000-0000000000b4', '00000000-0000-0000-0000-0000000000a3', 'guchi', 'これはａｂｃを含む投稿');

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';

SELECT is(
  (SELECT count(*)::int FROM public.feed_posts WHERE id = '00000000-0000-0000-0000-0000000000b4'),
  0,
  'ミュートした言葉を含む投稿は、全角・半角・大文字小文字を区別せず一覧に出ない'
);

SELECT is(
  (SELECT count(*)::int FROM public.member_posts WHERE id = '00000000-0000-0000-0000-0000000000b4'),
  1,
  '言葉ミュートも詳細（ID指定）には適用しない'
);

RESET role;

-- 他の利用者のミュートは影響しない
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a3';
SELECT is(
  (SELECT count(*)::int FROM public.feed_posts WHERE id = '00000000-0000-0000-0000-0000000000b4'),
  1,
  '他の利用者のミュート設定は、自分の一覧に影響しない'
);

SELECT is(
  (SELECT count(*)::int FROM public.muted_words),
  0,
  '他の利用者のミュート設定は参照できない'
);
RESET role;

-- === 上限（暫定：言葉100件） ===
INSERT INTO public.muted_words (user_id, word)
SELECT '00000000-0000-0000-0000-0000000000a1', 'word-' || g FROM generate_series(1, 99) g;

SELECT throws_ok(
  $$insert into public.muted_words (user_id, word) values ('00000000-0000-0000-0000-0000000000a1', 'あと一つ')$$,
  '54000', 'LIMIT_EXCEEDED',
  'ミュートする言葉は100件を超えて登録できない（暫定の上限）'
);

SELECT * FROM finish();
ROLLBACK;
