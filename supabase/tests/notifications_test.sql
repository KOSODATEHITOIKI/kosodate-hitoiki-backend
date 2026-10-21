-- 通知・共感のまとめ通知・プッシュの配信キューの検証（Issue #19）。
-- 注意：auth.uid() は、単数形の request.jwt.claim.sub を、JSONのclaimsより優先する。

BEGIN;
SELECT plan(46);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000d1'), -- 投稿者
  ('00000000-0000-0000-0000-0000000000d2'), -- コメントする人
  ('00000000-0000-0000-0000-0000000000d3'), -- 共感する人1
  ('00000000-0000-0000-0000-0000000000d4'), -- 共感する人2（投稿者がブロック）
  ('00000000-0000-0000-0000-0000000000d5'); -- 別の利用者（端末を使い回す）

INSERT INTO public.profiles (id, nickname, created_at) VALUES
  ('00000000-0000-0000-0000-0000000000d1', 'とうこうぬし', now() - interval '3 days'),
  ('00000000-0000-0000-0000-0000000000d2', 'こめんとする', now() - interval '3 days'),
  ('00000000-0000-0000-0000-0000000000d3', 'きょうかんいち', now() - interval '3 days'),
  ('00000000-0000-0000-0000-0000000000d4', 'きょうかんに', now() - interval '3 days'),
  ('00000000-0000-0000-0000-0000000000d5', 'べつのひと', now() - interval '3 days');

INSERT INTO public.notification_settings (user_id) VALUES
  ('00000000-0000-0000-0000-0000000000d1'),
  ('00000000-0000-0000-0000-0000000000d2')
ON CONFLICT DO NOTHING;

INSERT INTO public.posts (id, author_id, post_type, body, reaction_mode, comment_acceptance) VALUES
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d1', 'soudan', '相談', 'want_comments', 'open'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000d1', 'guchi', '愚痴', 'quiet_support', null);

-- === コメント・返信の通知 ===
INSERT INTO public.comments (id, post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d2', 'コメント');

SELECT is(
  (SELECT count(*)::int FROM public.notifications
   WHERE user_id = '00000000-0000-0000-0000-0000000000d1' AND notification_type = 'comment'),
  1, 'コメントは投稿者へ通知される');

INSERT INTO public.comments (id, post_id, author_id, parent_comment_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d1',
   '00000000-0000-0000-0000-0000000000a1', '返信');
SELECT is(
  (SELECT count(*)::int FROM public.notifications
   WHERE user_id = '00000000-0000-0000-0000-0000000000d2' AND notification_type = 'reply'),
  1, '返信は返信先コメントの投稿者へ通知される');
SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE user_id = '00000000-0000-0000-0000-0000000000d1' AND notification_type = 'reply'),
  0, '自分自身には通知しない');

-- 設定で止める：コメントと返信は別々に止められる
UPDATE public.notification_settings SET comments_enabled = false WHERE user_id = '00000000-0000-0000-0000-0000000000d1';
INSERT INTO public.comments (id, post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d3', '止めた後のコメント');
SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE comment_id = '00000000-0000-0000-0000-0000000000a3'),
  0, 'コメントの通知を止めていると、通知されない');

UPDATE public.notification_settings SET replies_enabled = false WHERE user_id = '00000000-0000-0000-0000-0000000000d2';
INSERT INTO public.comments (id, post_id, author_id, parent_comment_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d3',
   '00000000-0000-0000-0000-0000000000a1', '止めた後の返信');
SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE comment_id = '00000000-0000-0000-0000-0000000000a4'),
  0, '返信の通知を止めていると、通知されない（コメントの設定とは別）');

UPDATE public.notification_settings SET comments_enabled = true WHERE user_id = '00000000-0000-0000-0000-0000000000d1';
UPDATE public.notification_settings SET replies_enabled = true WHERE user_id = '00000000-0000-0000-0000-0000000000d2';

-- 同じコメントで2通は作れない
SELECT lives_ok(
  $$INSERT INTO public.notifications (user_id, notification_type, actor_id, post_id, comment_id)
    VALUES ('00000000-0000-0000-0000-0000000000d1', 'comment', '00000000-0000-0000-0000-0000000000d2',
            '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a1')
    ON CONFLICT DO NOTHING$$,
  '同じコメントの通知は重複しない');
SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE comment_id = '00000000-0000-0000-0000-0000000000a1'),
  1, '1つのコメントにつき通知は1通');

-- === 共感のまとめ通知 ===
INSERT INTO public.reaction_types (label, sort_order) VALUES ('わかる', 1), ('おつかれさま', 2);
INSERT INTO public.blocks (blocker_id, blocked_id) VALUES
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d4');

INSERT INTO public.reactions (post_id, user_id, reaction_type_id, created_at)
SELECT p.id, u.id, (SELECT min(id) FROM public.reaction_types), now() - interval '2 hours'
FROM (VALUES ('00000000-0000-0000-0000-0000000000f1'::uuid), ('00000000-0000-0000-0000-0000000000f2'::uuid)) p(id),
     (VALUES ('00000000-0000-0000-0000-0000000000d3'::uuid), ('00000000-0000-0000-0000-0000000000d4'::uuid)) u(id);
-- 自分の投稿への共感（数えない）
INSERT INTO public.reactions (post_id, user_id, reaction_type_id, created_at)
VALUES ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000d1', (SELECT min(id) FROM public.reaction_types), now() - interval '2 hours');

SELECT is(public.generate_reaction_digests(now()), 1, '共感があった投稿者に、まとめ通知が1通できる');
SELECT is(
  (SELECT reaction_count FROM public.notifications
   WHERE user_id = '00000000-0000-0000-0000-0000000000d1' AND notification_type = 'reaction_digest'),
  2, '数えるのは、ブロックした相手と自分の共感を除いた2件（2投稿×共感する人1）');
SELECT is(
  (SELECT actor_id FROM public.notifications WHERE notification_type = 'reaction_digest'),
  NULL, 'まとめ通知は、誰が共感したかを持たない');
SELECT is(public.generate_reaction_digests(now()), 0, '同じ日にもう一度動かしても、重複しない');

-- 翌日：新しい共感がなければ通知しない。あれば、前回以降の分だけ数える
SELECT is(public.generate_reaction_digests(now() + interval '1 day'), 0, '新しい共感がなければ、まとめ通知は作らない');
INSERT INTO public.reactions (post_id, user_id, reaction_type_id, created_at)
VALUES ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d5', (SELECT min(id) FROM public.reaction_types), now() + interval '25 hours');
SELECT is(public.generate_reaction_digests(now() + interval '2 days'), 1, '翌々日、新しい共感があればまとめ通知ができる');
SELECT is(
  (SELECT reaction_count FROM public.notifications
   WHERE notification_type = 'reaction_digest' ORDER BY created_at DESC, digest_date DESC LIMIT 1),
  1, '前回以降の共感だけを数える（前回分を重ねて数えない）');

-- 一時非表示の投稿への共感・設定で止めている人は数えない
UPDATE public.posts SET hidden_at = now() WHERE id = '00000000-0000-0000-0000-0000000000f2';
INSERT INTO public.reactions (post_id, user_id, reaction_type_id, created_at)
VALUES ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000d5', (SELECT min(id) FROM public.reaction_types), now() + interval '49 hours');
SELECT is(public.generate_reaction_digests(now() + interval '3 days'), 0, '一時非表示の投稿への共感は通知しない');
UPDATE public.posts SET hidden_at = null WHERE id = '00000000-0000-0000-0000-0000000000f2';
UPDATE public.notification_settings SET reactions_enabled = false WHERE user_id = '00000000-0000-0000-0000-0000000000d1';
SELECT is(public.generate_reaction_digests(now() + interval '4 days'), 0, '共感の通知を止めていると、まとめ通知は作らない');
UPDATE public.notification_settings SET reactions_enabled = true WHERE user_id = '00000000-0000-0000-0000-0000000000d1';

-- 集計のあとにコミットされた共感は、次回に数える（外部レビューの指摘）。
-- 共感R1は集計の前に確定している。共感R2は、集計の「前」の時刻で作られたが、集計の「あと」に確定した（長いトランザクション）。
-- 以前は、前回の集計の時刻より前のR2を、次回も数えなかった。
INSERT INTO public.reactions (post_id, user_id, reaction_type_id, created_at)
VALUES ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d2', (SELECT min(id) FROM public.reaction_types), now() + interval '5 days' - interval '1 hour');
SELECT is(public.generate_reaction_digests(now() + interval '5 days'), 1, '集計：まとめ通知ができる');
SELECT is(
  (SELECT reaction_count FROM public.notifications
   WHERE notification_type = 'reaction_digest' AND digest_date = ((now() + interval '5 days') at time zone 'Asia/Tokyo')::date),
  2, '集計に入ったのは、R1と、止めている間に溜まっていた共感の2件');
INSERT INTO public.reactions (post_id, user_id, reaction_type_id, created_at)
VALUES ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000d2', (SELECT min(id) FROM public.reaction_types), now() + interval '5 days' - interval '2 hours');
SELECT is(public.generate_reaction_digests(now() + interval '6 days'), 1, '集計のあとに確定した共感（時刻は前回の集計より前）も、次回のまとめ通知に入る');
SELECT is(
  (SELECT reaction_count FROM public.notifications
   WHERE notification_type = 'reaction_digest' AND digest_date = ((now() + interval '6 days') at time zone 'Asia/Tokyo')::date),
  1, '次回に数えたのは、そのR2の1件（前回に数えた分は重ねない）');

-- 定期実行が登録されている（毎日22:00 UTC＝日本時間の朝7時）
SELECT is(
  (SELECT schedule FROM cron.job WHERE jobname = 'reaction-digest-daily'),
  '0 22 * * *', '共感のまとめ通知は、毎朝7時（日本時間）に実行される');

-- === 端末の登録とプッシュの配信キュー ===
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000d1';
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}';

SELECT lives_ok($$SELECT public.register_push_device('ios', 'token-of-user-d1-ios-0001')$$, '端末を登録できる');
SELECT lives_ok($$SELECT public.register_push_device('ios', 'token-of-user-d1-ios-0001')$$, '同じ端末の再登録は成功する（更新）');
SELECT is((SELECT count(*)::int FROM public.push_devices WHERE device_token = 'token-of-user-d1-ios-0001'), 1, '同じトークンの行は1つのまま');
SELECT throws_ok($$SELECT public.register_push_device('windows', 'token-of-user-d1-xxxx')$$, 'P0001', 'VALIDATION_FAILED', '不正なプラットフォームは拒否される');
SELECT throws_ok($$SELECT public.register_push_device('ios', 'short')$$, 'P0001', 'VALIDATION_FAILED', '短すぎるトークンは拒否される');
SELECT throws_ok(
  $$INSERT INTO public.push_devices (user_id, platform, device_token) VALUES ('00000000-0000-0000-0000-0000000000d1', 'ios', 'direct-insert-token-1')$$,
  '42501', NULL, '端末の直接の登録は、できない（登録は関数だけ）');
SELECT throws_ok($$SELECT count(*) FROM public.push_deliveries$$, '42501', NULL, '配信キューは、利用者から読めない');
SELECT throws_ok($$SELECT public.claim_push_deliveries(10)$$, '42501', NULL, '配信の取り出しは、利用者から呼べない');

RESET ROLE;
SET LOCAL request.jwt.claim.sub = '';

-- 端末が登録されたあとにできた通知にだけ、配信ができる
INSERT INTO public.comments (id, post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d3', '端末登録後のコメント');
SELECT is(
  (SELECT count(*)::int FROM public.push_deliveries pd JOIN public.notifications n ON n.id = pd.notification_id
   WHERE n.comment_id = '00000000-0000-0000-0000-0000000000a5'),
  1, '通知ができると、端末ごとに配信が積まれる');

-- プッシュ全体を止めている人には積まない（アプリ内の通知は作られる）
UPDATE public.notification_settings SET push_enabled = false WHERE user_id = '00000000-0000-0000-0000-0000000000d1';
INSERT INTO public.comments (id, post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d3', 'プッシュ停止中のコメント');
SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE comment_id = '00000000-0000-0000-0000-0000000000a6'), 1,
  'プッシュを止めていても、アプリ内の通知は作られる');
SELECT is(
  (SELECT count(*)::int FROM public.push_deliveries pd JOIN public.notifications n ON n.id = pd.notification_id
   WHERE n.comment_id = '00000000-0000-0000-0000-0000000000a6'),
  0, 'プッシュを止めていると、配信は積まれない');
UPDATE public.notification_settings SET push_enabled = true WHERE user_id = '00000000-0000-0000-0000-0000000000d1';

-- 取り出し：設定を止めた・既読にしたものは送らない
SELECT is(
  (SELECT count(*)::int FROM public.claim_push_deliveries(50)), 1, '送るべき配信だけが取り出される');
SELECT is(
  (SELECT count(*)::int FROM public.claim_push_deliveries(50)), 0, '取り出し中の配信は、別の取り出しに重ならない（ロック中）');

UPDATE public.push_deliveries SET locked_until = null;
UPDATE public.notifications SET is_read = true WHERE comment_id = '00000000-0000-0000-0000-0000000000a5';
SELECT is((SELECT count(*)::int FROM public.claim_push_deliveries(50)), 0, '既読にした通知は送らない');
SELECT is((SELECT status FROM public.push_deliveries LIMIT 1), 'skipped', '既読の配信は skipped になる');
UPDATE public.notifications SET is_read = false WHERE comment_id = '00000000-0000-0000-0000-0000000000a5';

-- 結果の記録：再試行は 1・5・25・125 分後、5回目で打ち切り
INSERT INTO public.comments (id, post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d3', '再試行のコメント');
CREATE TEMP TABLE one_delivery AS
  SELECT pd.id FROM public.push_deliveries pd JOIN public.notifications n ON n.id = pd.notification_id
  WHERE n.comment_id = '00000000-0000-0000-0000-0000000000a7';

SELECT public.finish_push_delivery((SELECT id FROM one_delivery), 'retry', 'FCM_503');
SELECT is(
  (SELECT attempts || ':' || status FROM public.push_deliveries WHERE id = (SELECT id FROM one_delivery)), '1:pending',
  '一時的な失敗は、回数を増やして再試行に回る');
SELECT ok(
  (SELECT next_attempt_at > now() + interval '30 seconds' AND next_attempt_at < now() + interval '2 minutes'
   FROM public.push_deliveries WHERE id = (SELECT id FROM one_delivery)),
  '1回目の失敗の再試行は、約1分後');
SELECT public.finish_push_delivery((SELECT id FROM one_delivery), 'retry', 'select * from secrets');
SELECT is(
  (SELECT last_error FROM public.push_deliveries WHERE id = (SELECT id FROM one_delivery)), 'UNKNOWN',
  'エラーコードの形でないものは記録しない（本文・トークンを残さない）');
SELECT public.finish_push_delivery((SELECT id FROM one_delivery), 'retry', 'FCM_503');
SELECT public.finish_push_delivery((SELECT id FROM one_delivery), 'retry', 'FCM_503');
SELECT public.finish_push_delivery((SELECT id FROM one_delivery), 'retry', 'FCM_503');
SELECT is(
  (SELECT attempts || ':' || status FROM public.push_deliveries WHERE id = (SELECT id FROM one_delivery)), '5:failed',
  '5回失敗したら打ち切る');

INSERT INTO public.comments (id, post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000a8', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d3', '成功するコメント');
SELECT public.finish_push_delivery(
  (SELECT pd.id FROM public.push_deliveries pd JOIN public.notifications n ON n.id = pd.notification_id
   WHERE n.comment_id = '00000000-0000-0000-0000-0000000000a8'), 'sent');
SELECT is(
  (SELECT count(*)::int FROM public.push_deliveries WHERE status = 'sent' AND sent_at IS NOT NULL), 1,
  '送れた配信は sent になる');

-- 無効な端末：端末ごと削除される
INSERT INTO public.comments (id, post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000a9', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d3', '無効端末のコメント');
SELECT public.finish_push_delivery(
  (SELECT pd.id FROM public.push_deliveries pd JOIN public.notifications n ON n.id = pd.notification_id
   WHERE n.comment_id = '00000000-0000-0000-0000-0000000000a9'), 'invalid_token');
SELECT is(
  (SELECT count(*)::int FROM public.push_devices WHERE device_token = 'token-of-user-d1-ios-0001'), 0,
  '無効な端末は削除される');
SELECT is((SELECT count(*)::int FROM public.push_deliveries), 0, '無効な端末の配信も一緒に消える');

-- === 端末を別の人が使い始めたとき：前の人宛ての配信は、新しい人の端末へ届かない ===
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000d1';
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
SELECT public.register_push_device('android', 'shared-device-token-0001');
RESET ROLE;
SET LOCAL request.jwt.claim.sub = '';

INSERT INTO public.comments (id, post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d3', '前の持ち主宛てのコメント');
SELECT is((SELECT count(*)::int FROM public.push_deliveries), 1, '前の持ち主宛ての配信が積まれている');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000d5';
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000d5","role":"authenticated"}';
SELECT public.register_push_device('android', 'shared-device-token-0001');
SELECT is(
  (SELECT count(*)::int FROM public.push_devices WHERE device_token = 'shared-device-token-0001'
     AND user_id = '00000000-0000-0000-0000-0000000000d5'), 1, '端末の持ち主が新しい人に移る');
RESET ROLE;
SET LOCAL request.jwt.claim.sub = '';
SELECT is((SELECT count(*)::int FROM public.push_deliveries), 0, '前の持ち主宛ての未送信の配信は、新しい人の端末には届かない（消える）');

SELECT * FROM finish();
ROLLBACK;
