-- 投稿の日本語検索・一覧・ページングの検証（Issue #16）。
-- search_posts は security definer で公開条件を関数の中に持つため、既存のビュー（public_posts・
-- feed_posts）と同じ結果になることを、ここで確認する（差が出ると漏えいになる）。

BEGIN;
SELECT plan(46);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000a1'), -- 投稿者
  ('00000000-0000-0000-0000-0000000000a2'), -- 閲覧者（ログイン済み）
  ('00000000-0000-0000-0000-0000000000a3'); -- ブロックされる投稿者

INSERT INTO public.profiles (id, nickname) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'とうこうしゃ'),
  ('00000000-0000-0000-0000-0000000000a2', 'えつらん'),
  ('00000000-0000-0000-0000-0000000000a3', 'ぶろっく');

INSERT INTO public.topics (id, label) OVERRIDING SYSTEM VALUE VALUES (1, '睡眠'), (2, '食事');

-- 投稿（日時は固定して、並びとページングを確かめる）
INSERT INTO public.posts (id, author_id, post_type, topic_id, body, created_at) VALUES
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', 'guchi',  1, '夜泣きが毎晩つらい',                 '2026-10-01 10:00:00+00'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a1', 'soudan', 1, '保育園の送迎と夜泣きで悩んでいます', '2026-10-02 10:00:00+00'),
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000a1', 'kotsu',  2, '離乳食はまとめて冷凍すると楽',       '2026-10-03 10:00:00+00'),
  ('00000000-0000-0000-0000-0000000000b4', '00000000-0000-0000-0000-0000000000a3', 'guchi',  null, 'ブロックされた人の夜泣きの話',   '2026-10-04 10:00:00+00'),
  ('00000000-0000-0000-0000-0000000000b5', '00000000-0000-0000-0000-0000000000a1', 'guchi',  null, 'ＮＥＴＡバレに注意。ｱｲｳ',        '2026-10-05 10:00:00+00'),
  ('00000000-0000-0000-0000-0000000000b6', '00000000-0000-0000-0000-0000000000a1', 'guchi',  null, '一時非表示の夜泣きの投稿',        '2026-10-06 10:00:00+00');
UPDATE public.posts SET hidden_at = now() WHERE id = '00000000-0000-0000-0000-0000000000b6';

-- コメントの本文にだけ含まれる語は、検索に混入しない
INSERT INTO public.comments (post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000a2', 'コメントだけにあるひみつの言葉');

-- === 未ログイン（anon） ===
SET LOCAL role = 'anon';

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('夜泣き')),
  3,
  '未ログインで投稿本文を検索できる（一時非表示は除く）'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('夜')),
  3,
  '1文字でも検索できる'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('夜泣')),
  3,
  '2文字でも検索できる'
);

SELECT is(
  (SELECT array_agg(id ORDER BY created_at DESC) FROM public.search_posts('夜泣き')),
  ARRAY['00000000-0000-0000-0000-0000000000b4', '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b1']::uuid[],
  '結果は新着順（人気順・関連度順ではない）'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('ネタバレ')),
  0,
  '（確認）全角英字を含む語は、カタカナの語と別（ネタバレ ≠ ＮＥＴＡバレ）'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('neta')),
  1,
  '半角・小文字の検索語でも、全角の英字に一致する'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('ＮＥＴＡ')),
  1,
  '全角の検索語でも一致する'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('アイウ')),
  1,
  '全角カナの検索語は、半角カナの本文にも一致する'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('夜泣き 保育園')),
  1,
  '複数の語（空白区切り）は、全てを含む投稿だけに一致する（AND）'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('夜泣き　保育園')),
  1,
  '全角の空白でも語を区切れる'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('ひみつの言葉')),
  0,
  'コメントの本文は検索に混入しない'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('一時非表示')),
  0,
  '一時非表示の投稿は検索に出ない'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('')),
  5,
  '検索語が空なら、公開投稿の新着一覧になる（一時非表示は除く）'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('   ')),
  5,
  '空白だけの検索語も、空として扱う'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts(NULL)),
  5,
  'NULLの検索語も、空として扱う'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('ありえない語')),
  0,
  '一致しない語は0件'
);

-- 種類・話題での絞り込み
SELECT is(
  (SELECT array_agg(id) FROM public.search_posts('夜泣き', 'soudan')),
  ARRAY['00000000-0000-0000-0000-0000000000b2']::uuid[],
  '投稿の種類で絞り込める'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('', NULL, 1::smallint)),
  2,
  '話題で絞り込める'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('夜泣き', 'kotsu', 1::smallint)),
  0,
  '種類と話題を組み合わせられる'
);

-- 公開範囲：未ログインに利用者IDを出さない
SELECT is(
  (SELECT count(*)::int FROM public.search_posts('夜泣き') WHERE author_id IS NOT NULL),
  0,
  '未ログインには、投稿者の利用者ID（author_id）を返さない'
);

SELECT is(
  (SELECT author_nickname FROM public.search_posts('保育園')),
  'とうこうしゃ',
  '投稿者のニックネームは取得できる'
);

-- 入力の検証
SELECT throws_ok(
  $$select * from public.search_posts('夜泣き', 'invalid')$$,
  'P0001', 'VALIDATION_FAILED',
  '不正な投稿の種類は拒否される'
);

SELECT throws_ok(
  $$select * from public.search_posts('a b c d e f')$$,
  'P0001', 'VALIDATION_FAILED',
  '検索語は5語までに制限される'
);

SELECT throws_ok(
  $$select * from public.search_posts(repeat('あ', 101))$$,
  'P0001', 'VALIDATION_FAILED',
  '検索語は100文字までに制限される'
);

SELECT throws_ok(
  $$select * from public.search_posts('夜泣き', NULL, NULL, now(), NULL)$$,
  'P0001', 'VALIDATION_FAILED',
  'ページングのカーソルは、日時とIDが揃っていないと拒否される'
);

-- 検索語に含まれる記号・SQLの断片は、ただの文字として扱われる（インジェクションされない）
SELECT lives_ok(
  $$select * from public.search_posts($q$'; drop table public.posts; --$q$)$$,
  'SQLの断片を含む検索語でもエラーにならない'
);

SELECT lives_ok(
  $$select * from public.search_posts('%_\ "quoted" body:夜 OR (x)')$$,
  'PGroongaの検索構文やワイルドカードを含む検索語でもエラーにならず、ただの文字として扱われる'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('body:夜')),
  0,
  '「列名:語」のような検索構文は解釈されない（文字として一致しなければ0件）'
);

SELECT is(
  (SELECT to_regclass('public.posts') IS NOT NULL),
  true,
  '（確認）テーブルは消えていない'
);

-- 件数の上限
SELECT is(
  (SELECT count(*)::int FROM public.search_posts('', NULL, NULL, NULL, NULL, 2)),
  2,
  '件数を指定できる'
);

SELECT cmp_ok(
  (SELECT count(*)::int FROM public.search_posts('', NULL, NULL, NULL, NULL, 100000)),
  '<=', 50,
  '件数の上限は50件に抑えられる'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('', NULL, NULL, NULL, NULL, 0)),
  1,
  '件数が0以下なら、1件に直される'
);

RESET role;

-- === キーセット・ページング：同一時刻でも、重複・抜けがない ===
INSERT INTO public.posts (id, author_id, post_type, body, created_at)
SELECT ('00000000-0000-0000-0000-0000000001' || lpad(g::text, 2, '0'))::uuid,
       '00000000-0000-0000-0000-0000000000a1', 'guchi', 'ページング用の投稿' || g,
       '2026-11-01 00:00:00+00'  -- 全て同一時刻
FROM generate_series(1, 7) g;

SET LOCAL role = 'anon';

CREATE TEMP TABLE paged (page int, id uuid, created_at timestamptz);

DO $$
DECLARE
  cursor_at timestamptz := null;
  cursor_id uuid := null;
  p int := 0;
  got int;
BEGIN
  LOOP
    p := p + 1;
    INSERT INTO paged
      SELECT p, s.id, s.created_at FROM public.search_posts('ページング用', NULL, NULL, cursor_at, cursor_id, 3) s;
    GET DIAGNOSTICS got = ROW_COUNT;
    EXIT WHEN got < 3 OR p > 10;
    SELECT created_at, id INTO cursor_at, cursor_id FROM paged WHERE page = p ORDER BY created_at, id LIMIT 1;
  END LOOP;
END $$;

SELECT is(
  (SELECT count(*)::int FROM paged),
  7,
  '同一時刻の7件を3件ずつ辿ると、全部で7件になる（抜けがない）'
);

SELECT is(
  (SELECT count(DISTINCT id)::int FROM paged),
  7,
  '同一時刻でも、ページをまたいで重複しない'
);

SELECT is(
  (SELECT count(*)::int FROM paged WHERE page = 3),
  1,
  '最後のページは端数の1件'
);

RESET role;

-- === ログイン済み：feed_posts と同じ結果になる ===
INSERT INTO public.blocks (blocker_id, blocked_id) VALUES
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a3');
INSERT INTO public.hidden_items (user_id, target_type, target_id) VALUES
  ('00000000-0000-0000-0000-0000000000a2', 'post', '00000000-0000-0000-0000-0000000000b3');
INSERT INTO public.muted_topics (user_id, topic_id) VALUES ('00000000-0000-0000-0000-0000000000a2', 1);
INSERT INTO public.muted_words (user_id, word) VALUES ('00000000-0000-0000-0000-0000000000a2', 'ページング用の投稿1');

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a2';

SELECT is(
  (SELECT array_agg(id ORDER BY id) FROM public.search_posts('', NULL, NULL, NULL, NULL, 50)),
  (SELECT array_agg(id ORDER BY id) FROM public.feed_posts),
  'ログイン済みの一覧は、feed_posts（ブロック・非表示・ミュート適用）と同じ結果'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('夜泣き')),
  0,
  'ブロックした人・ミュートした話題・自分だけ非表示の投稿は、検索に出ない'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('ブロックされた人')),
  0,
  'ブロックした相手の投稿は検索に出ない'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('離乳食')),
  0,
  '自分だけ非表示にした投稿は、検索に出ない'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('ページング用の投稿1')),
  0,
  'ミュートした言葉を含む投稿は、検索に出ない'
);

SELECT is(
  (SELECT count(*)::int FROM public.search_posts('ＮＥＴＡ')),
  1,
  'ミュートの対象外の投稿は検索に出る'
);

SELECT isnt(
  (SELECT author_id FROM public.search_posts('neta')),
  NULL,
  'ログイン済みには、ブロック・通報のために投稿者の利用者IDを返す'
);

SELECT is(
  (SELECT array_agg(id ORDER BY id) FROM public.search_posts('', NULL, NULL, NULL, NULL, 50)
    WHERE id IN (SELECT id FROM public.posts WHERE hidden_at IS NOT NULL)),
  NULL,
  'ログイン済みでも、一時非表示の投稿は検索に出ない'
);

RESET role;

-- 別の閲覧者には、この閲覧者の設定が影響しない
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
SELECT is(
  (SELECT count(*)::int FROM public.search_posts('夜泣き')),
  3,
  '別の利用者のブロック・ミュート・非表示は、自分の検索結果に影響しない（自分の投稿も含む）'
);
RESET role;

-- 権限：未ログインが、定義者権限で内部のテーブルを直接読めるわけではない
SET LOCAL role = 'anon';
SELECT throws_ok(
  $$select count(*) from public.muted_words$$,
  '42501', null,
  '検索関数があっても、未ログインは muted_words を直接読めない'
);
SELECT throws_ok(
  $$select count(*) from public.profiles$$,
  '42501', null,
  '検索関数があっても、未ログインは profiles を直接読めない'
);
RESET role;

SELECT * FROM finish();
ROLLBACK;
