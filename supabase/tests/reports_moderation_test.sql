-- 通報・自動一時非表示・運営の対処の検証（Issue #17）。
-- 同時通報での3人到達は、pgTAPでは検証できないため supabase/tests/concurrency/run.sh で検証する。
-- 注意：auth.uid() は、単数形の request.jwt.claim.sub を、JSONのclaimsより優先する。
--       ロールを切り替えるたびに、claim.sub を空にしてからclaimsを設定する。

BEGIN;
SELECT plan(69);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000a1'), -- 投稿者（通報される側）
  ('00000000-0000-0000-0000-0000000000a2'), -- 通報者1
  ('00000000-0000-0000-0000-0000000000a3'), -- 通報者2
  ('00000000-0000-0000-0000-0000000000a4'), -- 通報者3
  ('00000000-0000-0000-0000-0000000000a5'), -- 運営者
  ('00000000-0000-0000-0000-0000000000a6'), -- 利用停止中
  ('00000000-0000-0000-0000-0000000000a7'), -- プロフィール未作成
  ('00000000-0000-0000-0000-0000000000a8'); -- 通報者4

INSERT INTO public.profiles (id, nickname) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'つうほうされる'),
  ('00000000-0000-0000-0000-0000000000a2', 'つうほうしゃいち'),
  ('00000000-0000-0000-0000-0000000000a3', 'つうほうしゃに'),
  ('00000000-0000-0000-0000-0000000000a4', 'つうほうしゃさん'),
  ('00000000-0000-0000-0000-0000000000a5', 'うんえい'),
  ('00000000-0000-0000-0000-0000000000a6', 'ていしちゅう'),
  ('00000000-0000-0000-0000-0000000000a8', 'つうほうしゃよん');

INSERT INTO public.admin_users (user_id) VALUES ('00000000-0000-0000-0000-0000000000a5');

INSERT INTO public.account_restrictions (user_id, stage, ends_at, created_by) VALUES
  ('00000000-0000-0000-0000-0000000000a6', 1, now() + interval '7 days', '00000000-0000-0000-0000-0000000000a5');

INSERT INTO public.posts (id, author_id, post_type, body, reaction_mode, comment_acceptance) VALUES
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', 'guchi',  '通報される投稿', 'quiet_support', null),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a1', 'soudan', '別の投稿',       'want_comments', 'open'),
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000a1', 'guchi',  '運営が削除する投稿', 'quiet_support', null);
INSERT INTO public.comments (id, post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a1', '通報されるコメント');

-- === 通報の作成 ===
SELECT is(
  (public.create_report('00000000-0000-0000-0000-0000000000a2', 'post', '00000000-0000-0000-0000-0000000000b1', 'harassment', null) ->> 'duplicate')::boolean,
  false,
  '通報を作成できる'
);

SELECT is(
  (public.create_report('00000000-0000-0000-0000-0000000000a2', 'post', '00000000-0000-0000-0000-0000000000b1', 'spam', '重複') ->> 'duplicate')::boolean,
  true,
  '同じ人が同じ対象を通報し直しても、重複せず既存の通報を返す'
);

SELECT is(
  (SELECT count(*)::int FROM public.reports WHERE reporter_id = '00000000-0000-0000-0000-0000000000a2'),
  1,
  '重複した通報は、件数が増えない'
);

SELECT is(
  (SELECT reason FROM public.reports WHERE reporter_id = '00000000-0000-0000-0000-0000000000a2'),
  'harassment',
  '重複の通報で、最初の理由が書き換えられない'
);

SELECT lives_ok(
  $$select public.create_report('00000000-0000-0000-0000-0000000000a2', 'comment', '00000000-0000-0000-0000-0000000000c1', 'personal_info', '名前が書いてある')$$,
  'コメントも通報できる（詳細を添えられる）'
);

SELECT throws_ok(
  $$select public.create_report('00000000-0000-0000-0000-0000000000a2', 'post', '00000000-0000-0000-0000-0000000000b2', 'invalid_reason', null)$$,
  'P0001', 'VALIDATION_FAILED',
  '通報理由は6種のどれかでなければならない'
);

SELECT lives_ok(
  $$select public.create_report('00000000-0000-0000-0000-0000000000a3', 'post', '00000000-0000-0000-0000-0000000000b2', 'danger', null)$$,
  '「危険を感じる内容」も通報できる'
);

SELECT lives_ok(
  $$select public.create_report('00000000-0000-0000-0000-0000000000a3', 'post', '00000000-0000-0000-0000-0000000000b3', 'other', 'その他の一言')$$,
  '「その他」は一言添えて通報できる'
);

SELECT throws_ok(
  $$select public.create_report('00000000-0000-0000-0000-0000000000a1', 'post', '00000000-0000-0000-0000-0000000000b1', 'spam', null)$$,
  'P0001', 'FORBIDDEN',
  '自分の投稿は通報できない'
);

SELECT throws_ok(
  $$select public.create_report('00000000-0000-0000-0000-0000000000a2', 'post', gen_random_uuid(), 'spam', null)$$,
  'P0001', 'NOT_FOUND',
  '存在しない投稿は通報できない'
);

SELECT throws_ok(
  $$select public.create_report('00000000-0000-0000-0000-0000000000a7', 'post', '00000000-0000-0000-0000-0000000000b1', 'spam', null)$$,
  'P0001', 'PROFILE_REQUIRED',
  'プロフィール未作成の利用者は通報できない'
);

SELECT throws_ok(
  $$select public.create_report('00000000-0000-0000-0000-0000000000a6', 'post', '00000000-0000-0000-0000-0000000000b1', 'spam', null)$$,
  'P0001', 'RESTRICTED',
  '利用停止中は通報できない'
);

-- ブロック関係があっても、通報はできる（通報は運営へ届くもので、相手には届かない）
INSERT INTO public.blocks (blocker_id, blocked_id) VALUES
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a8');

SELECT lives_ok(
  $$select public.create_report('00000000-0000-0000-0000-0000000000a8', 'post', '00000000-0000-0000-0000-0000000000b1', 'harassment', null)$$,
  'ブロックされた側も、通報はできる（安全のため妨げない）'
);

-- === 自動一時非表示：異なる3人で一時非表示 ===
-- b1 は、a2（上）とa8（ブロックされた通報者）の2人。3人目で非表示になる。
SELECT is(
  (SELECT hidden_at IS NULL FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000b1'),
  true,
  '通報者が2人までは、一時非表示にならない'
);

SELECT public.create_report('00000000-0000-0000-0000-0000000000a3', 'post', '00000000-0000-0000-0000-0000000000b1', 'spam', null);

SELECT isnt(
  (SELECT hidden_at FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000b1'),
  NULL,
  '異なる3人から通報されると、自動で一時非表示になる'
);

SELECT throws_ok(
  $$select public.create_report('00000000-0000-0000-0000-0000000000a4', 'post', '00000000-0000-0000-0000-0000000000b1', 'spam', null)$$,
  'P0001', 'NOT_FOUND',
  '一時非表示の投稿は、通報の対象としても見えない（存在を知る手がかりにしない）'
);

-- === 一時非表示中：本人に「確認中」を返し、ほかの人には見せない ===
RESET role;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';

SELECT is(
  (SELECT under_review FROM public.my_posts WHERE id = '00000000-0000-0000-0000-0000000000b1'),
  true,
  '一時非表示の投稿は、投稿者本人に「確認中」（under_review）として見える'
);

SELECT is(
  (SELECT under_review FROM public.my_posts WHERE id = '00000000-0000-0000-0000-0000000000b2'),
  false,
  '通報されていない投稿は、確認中ではない'
);

SELECT is(
  (SELECT count(*)::int FROM public.feed_posts WHERE id = '00000000-0000-0000-0000-0000000000b1'),
  0,
  '一時非表示の投稿は、投稿者本人にも一覧には出ない（本人の確認は my_posts で行う）'
);

RESET role;

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a3';
SELECT is(
  (SELECT count(*)::int FROM public.my_posts),
  0,
  '他人の投稿は my_posts に出ない'
);
SELECT is(
  (SELECT count(*)::int FROM public.feed_posts WHERE id = '00000000-0000-0000-0000-0000000000b1'),
  0,
  '一時非表示の投稿は、ほかの利用者の一覧に出ない'
);
RESET role;

SET LOCAL role = 'anon';
SELECT is(
  (SELECT count(*)::int FROM public.public_posts WHERE id = '00000000-0000-0000-0000-0000000000b1'),
  0,
  '一時非表示の投稿は、未ログインにも出ない'
);
SELECT throws_ok(
  $$select count(*) from public.my_posts$$,
  '42501', null,
  '未ログインは my_posts を参照できない'
);
SELECT throws_ok(
  $$select count(*) from public.admin_report_queue$$,
  '42501', null,
  '未ログインは admin_report_queue を参照できない'
);
RESET role;

-- コメントの確認中
UPDATE public.comments SET hidden_at = now() WHERE id = '00000000-0000-0000-0000-0000000000c1';
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
SELECT is(
  (SELECT under_review FROM public.member_comments WHERE id = '00000000-0000-0000-0000-0000000000c1'),
  true,
  '一時非表示のコメントは、投稿者本人に「確認中」として見える'
);
RESET role;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a3';
SELECT is(
  (SELECT count(*)::int FROM public.member_comments WHERE id = '00000000-0000-0000-0000-0000000000c1'),
  0,
  '一時非表示のコメントは、ほかの利用者には見えない'
);
RESET role;
UPDATE public.comments SET hidden_at = null WHERE id = '00000000-0000-0000-0000-0000000000c1';

-- === 通報者の情報は、通報された側・ほかの人に出ない ===
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
SELECT is(
  (SELECT count(*)::int FROM public.reports),
  0,
  '通報された側は、通報（通報者）の情報を参照できない'
);
RESET role;

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a2';
SELECT is(
  (SELECT count(*)::int FROM public.reports),
  2,
  '通報者は、自分が行った通報だけを参照できる'
);
SELECT throws_ok(
  $$insert into public.reports (reporter_id, target_type, target_id, reason)
    values ('00000000-0000-0000-0000-0000000000a2', 'post', '00000000-0000-0000-0000-0000000000b2', 'spam')$$,
  '42501', null,
  '通報は直接書き込めない（Edge Functionのチェックを迂回できない）'
);
RESET role;

-- === 運営者：二段階認証前（aal1）では何も見えない ===
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '';
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a5","aal":"aal1"}';
SELECT is(
  (SELECT count(*)::int FROM public.admin_report_queue),
  0,
  '二段階認証前（aal1）の運営者は、通報一覧が見えない'
);
SELECT is(
  (SELECT count(*)::int FROM public.reports),
  0,
  '二段階認証前（aal1）の運営者は、通報（通報者の情報）が見えない'
);
RESET role;

-- === 運営者：二段階認証済み（aal2）の通報一覧 ===
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '';
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a5","aal":"aal2"}';

SELECT is(
  (SELECT report_count::int FROM public.admin_report_queue WHERE target_id = '00000000-0000-0000-0000-0000000000b1'),
  3,
  '通報一覧に、対象ごとの通報者数が出る'
);

SELECT is(
  (SELECT is_hidden FROM public.admin_report_queue WHERE target_id = '00000000-0000-0000-0000-0000000000b1'),
  true,
  '通報一覧に、一時非表示中かどうかが出る'
);

SELECT is(
  (SELECT reasons FROM public.admin_report_queue WHERE target_id = '00000000-0000-0000-0000-0000000000b1'),
  ARRAY['harassment', 'spam']::text[],
  '通報一覧に、理由（重複を除く）が出る'
);

SELECT is(
  (SELECT target_owner_id FROM public.admin_report_queue WHERE target_id = '00000000-0000-0000-0000-0000000000b1'),
  '00000000-0000-0000-0000-0000000000a1'::uuid,
  '通報一覧に、対象の投稿者（警告・利用停止の対象）が出る'
);

SELECT is(
  (SELECT body FROM public.admin_report_queue WHERE target_id = '00000000-0000-0000-0000-0000000000b1'),
  '通報される投稿',
  '運営者は、一時非表示の投稿の本文も確認できる'
);

SELECT is(
  (SELECT count(*)::int FROM public.admin_report_queue),
  4,
  '通報一覧は、対象ごと（投稿3件・コメント1件の4件）にまとまる'
);

SELECT is(
  (SELECT count(*)::int FROM public.reports),
  6,
  '運営者（二段階認証済み）は、通報（通報者の情報）を参照できる'
);
RESET role;

-- === 運営の対処 ===
SELECT throws_ok(
  $$select public.moderation_apply('00000000-0000-0000-0000-0000000000a2', 'post', '00000000-0000-0000-0000-0000000000b1', 'unhide', null)$$,
  'P0001', 'FORBIDDEN',
  '運営者でない利用者は、対処できない（DBでも確認する）'
);

SELECT throws_ok(
  $$select public.moderation_apply('00000000-0000-0000-0000-0000000000a5', 'post', '00000000-0000-0000-0000-0000000000b1', 'warn', '警告')$$,
  'P0001', 'VALIDATION_FAILED',
  '警告は投稿ではなく利用者への操作（組み合わせの不正は拒否される）'
);

SELECT throws_ok(
  $$select public.moderation_apply('00000000-0000-0000-0000-0000000000a5', 'post', '00000000-0000-0000-0000-0000000000b3', 'delete', null)$$,
  'P0001', 'VALIDATION_FAILED',
  '削除には、本人へ通知する理由が必要'
);

SELECT throws_ok(
  $$select public.moderation_apply('00000000-0000-0000-0000-0000000000a5', 'post', gen_random_uuid(), 'unhide', null)$$,
  'P0001', 'NOT_FOUND',
  '存在しない対象への対処は拒否される'
);

-- 再表示：未対応の通報がまとめて対応済みになり、一時非表示が解除される
SELECT lives_ok(
  $$select public.moderation_apply('00000000-0000-0000-0000-0000000000a5', 'post', '00000000-0000-0000-0000-0000000000b1', 'unhide', '誤検知のため再表示')$$,
  '運営者は一時非表示を再表示できる'
);

SELECT is(
  (SELECT hidden_at IS NULL FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000b1'),
  true,
  '再表示すると、一時非表示が解除される'
);

SELECT is(
  (SELECT count(*)::int FROM public.reports WHERE target_id = '00000000-0000-0000-0000-0000000000b1' AND resolved_at IS NULL),
  0,
  '再表示すると、対象の未対応の通報がすべて対応済みになる'
);

SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE user_id = '00000000-0000-0000-0000-0000000000a1' AND notification_type = 'moderation'),
  0,
  '再表示では、本人へ通知しない（確認中の表示が消えるだけ）'
);

-- 再表示のあとの再通報：3人集まっても、自動では再び非表示にならない。運営の確認対象にはなる
SELECT public.create_report('00000000-0000-0000-0000-0000000000a2', 'post', '00000000-0000-0000-0000-0000000000b1', 'spam', null);
SELECT public.create_report('00000000-0000-0000-0000-0000000000a3', 'post', '00000000-0000-0000-0000-0000000000b1', 'spam', null);
SELECT public.create_report('00000000-0000-0000-0000-0000000000a8', 'post', '00000000-0000-0000-0000-0000000000b1', 'spam', null);

SELECT is(
  (SELECT hidden_at IS NULL FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000b1'),
  true,
  '再表示後に再び3人が通報しても、自動では再び一時非表示にならない（運営が個別に確認する）'
);

SELECT is(
  (SELECT count(*)::int FROM public.reports WHERE target_id = '00000000-0000-0000-0000-0000000000b1' AND resolved_at IS NULL),
  3,
  '再表示後の新たな通報は、未対応として残り、運営の確認対象になる'
);

-- 削除：本人へ理由を通知し、未対応の通報を対応済みにする
SELECT lives_ok(
  $$select public.moderation_apply('00000000-0000-0000-0000-0000000000a5', 'post', '00000000-0000-0000-0000-0000000000b3', 'delete', '個人情報が含まれていたため削除')$$,
  '運営者は投稿を削除できる（理由つき）'
);

SELECT is(
  (SELECT count(*)::int FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000b3'),
  0,
  '削除すると投稿が消える'
);

SELECT is(
  (SELECT count(*)::int FROM public.reports WHERE target_id = '00000000-0000-0000-0000-0000000000b3' AND resolved_at IS NULL),
  0,
  '削除すると、対象の未対応の通報が対応済みになる'
);

SELECT is(
  (SELECT count(*)::int FROM public.notifications
     WHERE user_id = '00000000-0000-0000-0000-0000000000a1' AND notification_type = 'moderation'),
  1,
  '削除すると、本人へ通知が作られる'
);

-- 本人は、通知から対処の理由を読める。通報者の情報は含まれない
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
SELECT is(
  (SELECT m.reason FROM public.notifications n
     JOIN public.moderation_actions m ON m.id = n.moderation_action_id
    WHERE n.notification_type = 'moderation'),
  '個人情報が含まれていたため削除',
  '本人は、通知から対処の理由を読める'
);
SELECT is(
  (SELECT count(*)::int FROM public.moderation_actions),
  2,
  '本人が参照できる対処の記録は、自分が対象のもの（再表示・削除）だけ。通報者の情報は含まれない'
);
RESET role;

-- コメントの削除（ソフト削除）
SELECT lives_ok(
  $$select public.moderation_apply('00000000-0000-0000-0000-0000000000a5', 'comment', '00000000-0000-0000-0000-0000000000c1', 'delete', '不適切な内容のため削除')$$,
  '運営者はコメントを削除できる'
);
SELECT is(
  (SELECT deleted_at IS NOT NULL AND body IS NULL FROM public.comments WHERE id = '00000000-0000-0000-0000-0000000000c1'),
  true,
  'コメントの削除は、本文が消えるソフト削除'
);

-- 警告
SELECT lives_ok(
  $$select public.moderation_apply('00000000-0000-0000-0000-0000000000a5', 'user', '00000000-0000-0000-0000-0000000000a1', 'warn', '攻撃的な表現を繰り返しています')$$,
  '運営者は利用者に警告できる'
);

SELECT throws_ok(
  $$select public.moderation_apply('00000000-0000-0000-0000-0000000000a5', 'user', '00000000-0000-0000-0000-0000000000a5', 'warn', '自分自身')$$,
  'P0001', 'FORBIDDEN',
  '運営者自身には、警告・利用停止をかけられない'
);

-- 相談先の案内（理由は任意）
SELECT lives_ok(
  $$select public.moderation_apply('00000000-0000-0000-0000-0000000000a5', 'user', '00000000-0000-0000-0000-0000000000a2', 'guide', null)$$,
  '運営者は利用者へ相談先を案内できる（理由は任意）'
);

SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE user_id = '00000000-0000-0000-0000-0000000000a2' AND notification_type = 'moderation'),
  1,
  '相談先の案内は、本人への通知になる'
);

-- === 利用停止：段階（7日→30日→無期限） ===
SELECT is(
  (public.moderation_apply('00000000-0000-0000-0000-0000000000a5', 'user', '00000000-0000-0000-0000-0000000000a3', 'suspend', '悪質なため') ->> 'restriction_stage')::int,
  1,
  '初回の利用停止は、第1段階（7日間）'
);

SELECT is(
  (SELECT ends_at - starts_at FROM public.account_restrictions WHERE user_id = '00000000-0000-0000-0000-0000000000a3'),
  interval '7 days',
  '第1段階は7日間'
);

SELECT throws_ok(
  $$select public.moderation_apply('00000000-0000-0000-0000-0000000000a5', 'user', '00000000-0000-0000-0000-0000000000a3', 'suspend', '二重')$$,
  'P0001', 'CONFLICT',
  'すでに利用停止中の利用者には、重ねて停止しない（段階を二重に進めない）'
);

SELECT is(
  public.is_restricted('00000000-0000-0000-0000-0000000000a3'),
  true,
  '利用停止中として扱われる'
);

-- 期間が終わった（終了日時を過去にした）あとの再発 → 第2段階（30日）
UPDATE public.account_restrictions
  SET ends_at = now() - interval '1 minute', starts_at = now() - interval '8 days'
  WHERE user_id = '00000000-0000-0000-0000-0000000000a3';

SELECT is(
  (public.moderation_apply('00000000-0000-0000-0000-0000000000a5', 'user', '00000000-0000-0000-0000-0000000000a3', 'suspend', '再発') ->> 'restriction_stage')::int,
  2,
  '再発すると、第2段階（30日間）'
);

UPDATE public.account_restrictions
  SET ends_at = now() - interval '1 minute', starts_at = now() - interval '31 days'
  WHERE user_id = '00000000-0000-0000-0000-0000000000a3' AND stage = 2;

SELECT is(
  (public.moderation_apply('00000000-0000-0000-0000-0000000000a5', 'user', '00000000-0000-0000-0000-0000000000a3', 'suspend', '再々発') ->> 'restriction_stage')::int,
  3,
  '再発以降は、第3段階（無期限）'
);

SELECT is(
  (SELECT ends_at IS NULL FROM public.account_restrictions WHERE user_id = '00000000-0000-0000-0000-0000000000a3' AND stage = 3),
  true,
  '第3段階は無期限（終了日時なし）'
);

-- 早期解除（lifted_at）した分は、段階の数に含めない
UPDATE public.account_restrictions SET lifted_at = now() WHERE user_id = '00000000-0000-0000-0000-0000000000a3';
SELECT is(
  public.is_restricted('00000000-0000-0000-0000-0000000000a3'),
  false,
  '早期解除すると、利用停止ではなくなる'
);
SELECT is(
  (public.moderation_apply('00000000-0000-0000-0000-0000000000a5', 'user', '00000000-0000-0000-0000-0000000000a3', 'suspend', '解除後の再発') ->> 'restriction_stage')::int,
  1,
  '早期解除した過去の制限は、段階の数に含めない（解除後の最初は第1段階）'
);

SELECT * FROM finish();
ROLLBACK;
