-- 退会（withdraw_account）と、保持期限を過ぎた記録の削除（purge_expired_records）の検証（Issue #20）。

BEGIN;
SELECT plan(35);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000e1'), -- 退会する人
  ('00000000-0000-0000-0000-0000000000e2'), -- 他の利用者
  ('00000000-0000-0000-0000-0000000000e3'), -- 運営者
  ('00000000-0000-0000-0000-0000000000e4'); -- 退会する運営者（登録を外した後）

INSERT INTO public.profiles (id, nickname) VALUES
  ('00000000-0000-0000-0000-0000000000e1', 'たいかいする'),
  ('00000000-0000-0000-0000-0000000000e2', 'のこるひと'),
  ('00000000-0000-0000-0000-0000000000e3', 'うんえいしゃ'),
  ('00000000-0000-0000-0000-0000000000e4', 'もとうんえい');
INSERT INTO public.notification_settings (user_id) SELECT id FROM auth.users;
INSERT INTO public.terms_acceptances (user_id, terms_version) VALUES ('00000000-0000-0000-0000-0000000000e1', 'v1');
INSERT INTO public.admin_users (user_id) VALUES ('00000000-0000-0000-0000-0000000000e3');

-- 退会する人（E1）のデータ
INSERT INTO public.posts (id, author_id, post_type, body, reaction_mode, comment_acceptance) VALUES
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000e1', 'soudan', 'E1の投稿', 'want_comments', 'open'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000e2', 'soudan', 'E2の投稿', 'want_comments', 'open');
INSERT INTO public.comments (id, post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000e2', 'E2がE1の投稿へ'),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000e1', 'E1がE2の投稿へ');
INSERT INTO public.reaction_types (label, sort_order) VALUES ('わかる', 1);
INSERT INTO public.reactions (post_id, user_id, reaction_type_id) VALUES
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000e1', (SELECT min(id) FROM public.reaction_types)),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000e2', (SELECT min(id) FROM public.reaction_types));
INSERT INTO public.saved_posts (user_id, post_id) VALUES
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000f2'),
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000f1');
-- 他の人の「非表示」が、消える投稿・コメントを指している（外部キーのない論理参照）
INSERT INTO public.hidden_items (user_id, target_type, target_id) VALUES
  ('00000000-0000-0000-0000-0000000000e2', 'post', '00000000-0000-0000-0000-0000000000f1'),
  ('00000000-0000-0000-0000-0000000000e2', 'comment', '00000000-0000-0000-0000-0000000000c2'),
  ('00000000-0000-0000-0000-0000000000e2', 'post', '00000000-0000-0000-0000-0000000000f2');
INSERT INTO public.blocks (blocker_id, blocked_id) VALUES ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e2');
INSERT INTO public.muted_words (user_id, word) VALUES ('00000000-0000-0000-0000-0000000000e1', 'ことば');
INSERT INTO public.push_devices (user_id, platform, device_token) VALUES ('00000000-0000-0000-0000-0000000000e1', 'ios', 'withdraw-test-token-0001');
INSERT INTO public.idempotency_keys (user_id, endpoint, key) VALUES ('00000000-0000-0000-0000-0000000000e1', 'post.create', 'k1');

-- 通報：E1が通報した（E2の投稿へ）、E1の投稿が通報された（E2が通報）
INSERT INTO public.reports (id, reporter_id, target_type, target_id, reason) VALUES
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000e1', 'post', '00000000-0000-0000-0000-0000000000f2', 'other'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000e2', 'post', '00000000-0000-0000-0000-0000000000f1', 'spam');
-- 運営の対処：E1への警告（運営者E3）
INSERT INTO public.moderation_actions (id, admin_id, target_type, target_id, action, reason) VALUES
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000e3', 'user', '00000000-0000-0000-0000-0000000000e1', 'warn', '警告');
INSERT INTO public.account_restrictions (user_id, stage, ends_at, created_by) VALUES
  ('00000000-0000-0000-0000-0000000000e1', 1, now() + interval '7 days', '00000000-0000-0000-0000-0000000000e3');
-- E1が起こした通知（E2宛て）は、コメントの作成時にトリガーで作られている
SELECT is((SELECT count(*)::int FROM public.notifications WHERE actor_id = '00000000-0000-0000-0000-0000000000e1'), 1, '退会前：E1が起こした通知がある');

-- === 運営者として登録されている間は退会できない ===
SELECT throws_ok(
  $$SELECT public.withdraw_account('00000000-0000-0000-0000-0000000000e3')$$,
  'P0001', 'OPERATOR_REGISTERED', '運営者として登録されている間は、退会できない');
SELECT is((SELECT count(*)::int FROM auth.users WHERE id = '00000000-0000-0000-0000-0000000000e3'), 1,
  '拒否された退会では、何も消えない');

-- === 退会 ===
SELECT is(public.withdraw_account('00000000-0000-0000-0000-0000000000e1') ->> 'status', 'deleted', '退会できる');

SELECT is((SELECT count(*)::int FROM auth.users WHERE id = '00000000-0000-0000-0000-0000000000e1'), 0, 'Authのアカウントが消える');
SELECT is((SELECT count(*)::int FROM public.profiles WHERE id = '00000000-0000-0000-0000-0000000000e1'), 0, 'プロフィールが消える');
SELECT is((SELECT count(*)::int FROM public.posts WHERE author_id = '00000000-0000-0000-0000-0000000000e1'), 0, '投稿が消える');
SELECT is((SELECT count(*)::int FROM public.comments WHERE id = '00000000-0000-0000-0000-0000000000c2'), 0, '他の人の投稿へのコメントが消える');
SELECT is((SELECT count(*)::int FROM public.comments WHERE id = '00000000-0000-0000-0000-0000000000c1'), 0, '自分の投稿についていた、他の人のコメントも消える（投稿ごと）');
SELECT is((SELECT count(*)::int FROM public.reactions WHERE user_id = '00000000-0000-0000-0000-0000000000e1'), 0, '共感が消える');
SELECT is((SELECT count(*)::int FROM public.saved_posts WHERE user_id = '00000000-0000-0000-0000-0000000000e1'), 0, '保存が消える');
SELECT is((SELECT count(*)::int FROM public.blocks WHERE blocker_id = '00000000-0000-0000-0000-0000000000e1'), 0, 'ブロックが消える');
SELECT is((SELECT count(*)::int FROM public.muted_words WHERE user_id = '00000000-0000-0000-0000-0000000000e1'), 0, 'ミュートが消える');
SELECT is((SELECT count(*)::int FROM public.push_devices WHERE user_id = '00000000-0000-0000-0000-0000000000e1'), 0, '端末情報が消える');
SELECT is((SELECT count(*)::int FROM public.notification_settings WHERE user_id = '00000000-0000-0000-0000-0000000000e1'), 0, '通知設定が消える');
SELECT is((SELECT count(*)::int FROM public.terms_acceptances WHERE user_id = '00000000-0000-0000-0000-0000000000e1'), 0, '利用規約の同意が消える');
SELECT is((SELECT count(*)::int FROM public.idempotency_keys WHERE user_id = '00000000-0000-0000-0000-0000000000e1'), 0, '再送防止キーが消える');
SELECT is((SELECT count(*)::int FROM public.account_restrictions WHERE user_id = '00000000-0000-0000-0000-0000000000e1'), 0, '停止の履歴が消える');
SELECT is((SELECT count(*)::int FROM public.notifications WHERE actor_id = '00000000-0000-0000-0000-0000000000e1'), 0, '自分が起こした通知が消える');
SELECT is(
  (SELECT count(*)::int FROM public.hidden_items
   WHERE target_id IN ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c2')),
  0, '他の人の「非表示」のうち、消える投稿・コメントを指すものが消える');
SELECT is(
  (SELECT count(*)::int FROM public.hidden_items WHERE target_id = '00000000-0000-0000-0000-0000000000f2'),
  1, '残る投稿への「非表示」は残る');

-- === 他の人のデータは残る ===
SELECT is((SELECT count(*)::int FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000f2'), 1, '他の人の投稿は残る');
SELECT is((SELECT count(*)::int FROM public.profiles WHERE id = '00000000-0000-0000-0000-0000000000e2'), 1, '他の人のプロフィールは残る');
SELECT is((SELECT count(*)::int FROM public.saved_posts WHERE user_id = '00000000-0000-0000-0000-0000000000e2'), 0,
  '他の人の保存のうち、消えた投稿のものは外部キーで消える');

-- === 保持するもの ===
SELECT is(
  (SELECT reason || ':' || (reserved_until > now() + interval '29 days')::text FROM public.nickname_reservations
   WHERE normalized_nickname = public.normalize_nickname('たいかいする')),
  'withdrawn:true', 'ニックネームが30日間予約される');

SELECT throws_ok(
  $$INSERT INTO public.profiles (id, nickname) VALUES ('00000000-0000-0000-0000-0000000000e4', 'たいかいする')
    ON CONFLICT (id) DO UPDATE SET nickname = excluded.nickname$$,
  'P0001', 'この名前は現在使用できません', '予約中のニックネームは、他の人が使えない');

SELECT is(
  (SELECT reporter_id IS NULL AND resolved_at IS NULL FROM public.reports WHERE id = '00000000-0000-0000-0000-0000000000a1'),
  true, '退会した人の通報は記録として残り、通報者は空になる');
SELECT is(
  (SELECT resolved_at IS NOT NULL FROM public.reports WHERE id = '00000000-0000-0000-0000-0000000000a2'),
  true, '消えた投稿への通報は、対応済みになって記録が残る');
SELECT is(
  (SELECT target_owner_id FROM public.moderation_actions WHERE id = '00000000-0000-0000-0000-0000000000b1'),
  '00000000-0000-0000-0000-0000000000e1'::uuid, '運営の対処の記録は、退会後も保持期間まで残る');

-- === 再実行 ===
SELECT is(public.withdraw_account('00000000-0000-0000-0000-0000000000e1') ->> 'status', 'already_deleted',
  '退会済みへの再実行は、何も変えずに成功する（冪等）');

-- === 運営者の退会：登録を外せば退会でき、対処の記録は残る ===
DELETE FROM public.admin_users WHERE user_id = '00000000-0000-0000-0000-0000000000e3';
SELECT is(public.withdraw_account('00000000-0000-0000-0000-0000000000e3') ->> 'status', 'deleted', '運営者も、登録を外せば退会できる');
SELECT is(
  (SELECT admin_id IS NULL FROM public.moderation_actions WHERE id = '00000000-0000-0000-0000-0000000000b1'),
  true, '退会した運営者の対処の記録は残り、運営者は空になる');

-- === 保持期限を過ぎた記録の削除 ===
INSERT INTO public.moderation_actions (id, admin_id, target_type, target_id, action, reason, created_at) VALUES
  ('00000000-0000-0000-0000-0000000000b2', NULL, 'user', '00000000-0000-0000-0000-0000000000e2', 'warn', '古い', now() - interval '13 months');
INSERT INTO public.reports (id, reporter_id, target_type, target_id, reason, created_at) VALUES
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000e2', 'post', '00000000-0000-0000-0000-0000000000f2', 'other', now() - interval '13 months');
SELECT public.purge_expired_records();
SELECT is(
  (SELECT count(*)::int FROM public.moderation_actions WHERE id = '00000000-0000-0000-0000-0000000000b2'), 0,
  '1年を過ぎた対処の記録は削除される');
SELECT is(
  (SELECT count(*)::int FROM public.moderation_actions WHERE id = '00000000-0000-0000-0000-0000000000b1')
  + (SELECT count(*)::int FROM public.reports WHERE id = '00000000-0000-0000-0000-0000000000a2'),
  2, '1年以内の記録は残る');
SELECT is((SELECT count(*)::int FROM public.reports WHERE id = '00000000-0000-0000-0000-0000000000a3'), 0, '1年を過ぎた通報の記録は削除される');

SELECT * FROM finish();
ROLLBACK;
