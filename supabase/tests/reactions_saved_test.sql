-- 共感と保存の検証（Issue #15）。
-- 同時操作の競合は、pgTAPでは検証できないため supabase/tests/concurrency/run.sh で検証する。

BEGIN;
SELECT plan(37);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000a1'), -- 投稿者
  ('00000000-0000-0000-0000-0000000000a2'), -- 共感する人
  ('00000000-0000-0000-0000-0000000000a3'), -- 第三者
  ('00000000-0000-0000-0000-0000000000a4'), -- 利用停止中
  ('00000000-0000-0000-0000-0000000000a5'); -- ブロックされる人

INSERT INTO public.profiles (id, nickname) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'とうこうしゃ'),
  ('00000000-0000-0000-0000-0000000000a2', 'きょうかん'),
  ('00000000-0000-0000-0000-0000000000a3', 'だいさんしゃ'),
  ('00000000-0000-0000-0000-0000000000a4', 'ていしちゅう'),
  ('00000000-0000-0000-0000-0000000000a5', 'ぶろっく');

INSERT INTO public.account_restrictions (user_id, stage, ends_at, created_by) VALUES
  ('00000000-0000-0000-0000-0000000000a4', 1, now() + interval '7 days',
   '00000000-0000-0000-0000-0000000000a1');

INSERT INTO public.reaction_types (id, label, is_active) OVERRIDING SYSTEM VALUE VALUES
  (1, '大変だったね', true), (2, 'わかるよ', true), (3, '終了した定型文', false);

INSERT INTO public.posts (id, author_id, post_type, body, reaction_mode, comment_acceptance) VALUES
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', 'guchi', 'Aの投稿', 'quiet_support', null),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a1', 'soudan', '受付終了の投稿', 'want_comments', 'closed'),
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000a1', 'guchi', '一時非表示の投稿', 'quiet_support', null);
UPDATE public.posts SET hidden_at = now() WHERE id = '00000000-0000-0000-0000-0000000000b3';

INSERT INTO public.blocks (blocker_id, blocked_id) VALUES
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a5');

-- === 共感の登録・変更・取消 ===
SELECT is(
  (public.set_reaction('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b1', 1::smallint) ->> 'reaction_type_id')::int,
  1,
  '共感を登録できる'
);

SELECT is(
  (public.set_reaction('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b1', 2::smallint) ->> 'reaction_type_id')::int,
  2,
  '別の定型文へ選び直せる'
);

SELECT is(
  (SELECT count(*)::int FROM public.reactions WHERE post_id = '00000000-0000-0000-0000-0000000000b1'),
  1,
  '選び直しても、1投稿1人1つのまま'
);

SELECT is(
  public.get_post_reaction_count('00000000-0000-0000-0000-0000000000b1'),
  0::bigint,
  '（呼び出し者が投稿者でないため）件数は返らない'
);

SELECT is(
  (public.set_reaction('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b2', 1::smallint) ->> 'post_id')::uuid,
  '00000000-0000-0000-0000-0000000000b2'::uuid,
  'コメント受付終了後も共感できる'
);

SELECT throws_ok(
  $$select public.set_reaction('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b1', 3::smallint)$$,
  'P0001', 'VALIDATION_FAILED',
  '無効になった定型文は選べない'
);

SELECT throws_ok(
  $$select public.set_reaction('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b1', 99::smallint)$$,
  'P0001', 'VALIDATION_FAILED',
  '存在しない定型文は選べない'
);

SELECT throws_ok(
  $$select public.set_reaction('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', 1::smallint)$$,
  'P0001', 'FORBIDDEN',
  '自分の投稿には共感できない（暫定）'
);

SELECT throws_ok(
  $$select public.set_reaction('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b3', 1::smallint)$$,
  'P0001', 'NOT_FOUND',
  '一時非表示の投稿には共感できない'
);

SELECT throws_ok(
  $$select public.set_reaction('00000000-0000-0000-0000-0000000000a2', gen_random_uuid(), 1::smallint)$$,
  'P0001', 'NOT_FOUND',
  '存在しない投稿には共感できない（一時非表示と区別できない）'
);

SELECT throws_ok(
  $$select public.set_reaction('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000b1', 1::smallint)$$,
  'P0001', 'BLOCKED',
  '投稿者にブロックされた人は共感できない'
);

SELECT throws_ok(
  $$select public.set_reaction('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000b1', 1::smallint)$$,
  'P0001', 'RESTRICTED',
  '利用停止中は共感できない'
);

-- 削除済みの投稿には共感できない
INSERT INTO public.posts (id, author_id, post_type, body) VALUES
  ('00000000-0000-0000-0000-0000000000b9', '00000000-0000-0000-0000-0000000000a1', 'guchi', '削除する投稿');
SELECT public.delete_post('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b9');

SELECT throws_ok(
  $$select public.set_reaction('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b9', 1::smallint)$$,
  'P0001', 'NOT_FOUND',
  '削除済みの投稿には共感できない'
);

-- 取消
SELECT is(
  (public.remove_reaction('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b1') ->> 'deleted')::boolean,
  true,
  '共感を取り消せる'
);

SELECT is(
  (public.remove_reaction('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b1') ->> 'deleted')::boolean,
  false,
  '取り消し済みの共感を再度取り消しても、エラーにならない（冪等）'
);

SELECT is(
  (public.remove_reaction('00000000-0000-0000-0000-0000000000a2', gen_random_uuid()) ->> 'deleted')::boolean,
  false,
  '存在しない投稿の取消も成功を返す（投稿の存在を知る手がかりにしない）'
);

-- ブロックされても、既存の共感の取消はできる（自分の操作は妨げない）
INSERT INTO public.reactions (post_id, user_id, reaction_type_id) VALUES
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a5', 1);
SELECT is(
  (public.remove_reaction('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000b1') ->> 'deleted')::boolean,
  true,
  'ブロックされた人も、以前の共感は取り消せる'
);

-- === 共感の公開範囲（利用者の権限）===
SELECT public.set_reaction('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b1', 1::smallint);
SELECT public.set_reaction('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000b1', 2::smallint);

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
SELECT is(
  public.get_post_reaction_count('00000000-0000-0000-0000-0000000000b1'),
  2::bigint,
  '投稿者は共感件数を取得できる'
);
SELECT is(
  (SELECT count(*)::int FROM public.reactions),
  0,
  '投稿者でも、誰がどの共感をしたか（行）は取得できない'
);
RESET role;

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a2';
SELECT is(
  public.get_post_reaction_count('00000000-0000-0000-0000-0000000000b1'),
  0::bigint,
  '投稿者以外は共感件数を取得できない（0が返る）'
);
SELECT is(
  (SELECT reaction_type_id::int FROM public.reactions WHERE post_id = '00000000-0000-0000-0000-0000000000b1'),
  1,
  '自分の共感は参照できる'
);
SELECT throws_ok(
  $$insert into public.reactions (post_id, user_id, reaction_type_id)
    values ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a2', 2)$$,
  '42501', null,
  '共感は直接書き込めない（チェックを迂回できない）'
);
SELECT throws_ok(
  $$update public.reactions set reaction_type_id = 2$$,
  '42501', null,
  '共感を直接更新できない'
);
SELECT throws_ok(
  $$delete from public.reactions$$,
  '42501', null,
  '共感を直接削除できない'
);
RESET role;

-- === 保存 ===
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a2';

SELECT lives_ok(
  $$insert into public.saved_posts (user_id, post_id) values
    ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b1')$$,
  '公開中の投稿を保存できる'
);

SELECT throws_ok(
  $$insert into public.saved_posts (user_id, post_id) values
    ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b1')$$,
  '23505', null,
  '同じ投稿の重複した保存は、一意制約で拒否される'
);

SELECT throws_ok(
  $$insert into public.saved_posts (user_id, post_id) values
    ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b3')$$,
  '42501', null,
  '一時非表示の投稿は保存できない'
);

SELECT throws_ok(
  $$insert into public.saved_posts (user_id, post_id) values
    ('00000000-0000-0000-0000-0000000000a2', gen_random_uuid())$$,
  '42501', null,
  '存在しない投稿の保存は、非表示と同じエラーで、投稿の存在を知る手がかりにならない'
);

SELECT throws_ok(
  $$insert into public.saved_posts (user_id, post_id) values
    ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000b2')$$,
  '42501', null,
  '他人の名義で保存できない'
);

SELECT is(
  (SELECT count(*)::int FROM public.saved_post_list),
  1,
  '保存一覧に、保存した投稿が出る'
);

SELECT is(
  (SELECT saved_at IS NOT NULL FROM public.saved_post_list),
  true,
  '保存一覧には保存日時が付く'
);

RESET role;

-- 保存した投稿が見えなくなると、保存一覧から消える（保存自体は残る）
UPDATE public.posts SET hidden_at = now() WHERE id = '00000000-0000-0000-0000-0000000000b1';
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a2';
SELECT is(
  (SELECT count(*)::int FROM public.saved_post_list),
  0,
  '保存した投稿が一時非表示になると、保存一覧に出ない'
);
RESET role;
UPDATE public.posts SET hidden_at = null WHERE id = '00000000-0000-0000-0000-0000000000b1';

-- 他人に保存を見せない・通知しない
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
SELECT is(
  (SELECT count(*)::int FROM public.saved_posts) + (SELECT count(*)::int FROM public.saved_post_list),
  0,
  '投稿者でも、誰が保存したかは見えない（保存数・保存した事実は公開しない）'
);
SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE notification_type NOT IN ('comment', 'reply')),
  0,
  '保存・共感では、投稿者へ通知は作られない（共感のまとめ通知は#19）'
);
RESET role;

SET LOCAL role = 'anon';
SELECT throws_ok(
  $$select count(*) from public.saved_post_list$$,
  '42501', null,
  '未ログインは保存一覧を参照できない'
);
RESET role;

-- 保存解除
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a2';
SELECT lives_ok(
  $$delete from public.saved_posts where post_id = '00000000-0000-0000-0000-0000000000b1'$$,
  '保存を解除できる'
);
RESET role;

-- 投稿を削除すると、共感・保存も消える
SELECT public.set_reaction('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000b2', 1::smallint);
INSERT INTO public.saved_posts (user_id, post_id) VALUES
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000b2');
SELECT public.delete_post('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2');
SELECT is(
  (SELECT count(*)::int FROM public.reactions WHERE post_id = '00000000-0000-0000-0000-0000000000b2')
  + (SELECT count(*)::int FROM public.saved_posts WHERE post_id = '00000000-0000-0000-0000-0000000000b2'),
  0,
  '投稿を削除すると、共感・保存も一緒に消える'
);

SELECT * FROM finish();
ROLLBACK;
