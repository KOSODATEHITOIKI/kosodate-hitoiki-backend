-- コメントを削除したときの後始末（通知・配信待ちのプッシュ・本人だけの非表示）の検証（外部レビューの指摘）。
-- 本人の削除でも、運営の削除でも、同じ後始末になること。

BEGIN;
SELECT plan(12);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000a1'), -- 投稿者A（通知を受ける。端末あり）
  ('00000000-0000-0000-0000-0000000000a2'), -- コメントするB
  ('00000000-0000-0000-0000-0000000000a5'); -- 運営者
INSERT INTO public.profiles (id, nickname, created_at) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'えー', now() - interval '3 days'),
  ('00000000-0000-0000-0000-0000000000a2', 'びー', now() - interval '3 days'),
  ('00000000-0000-0000-0000-0000000000a5', 'うんえい', now() - interval '3 days');
INSERT INTO public.admin_users (user_id) VALUES ('00000000-0000-0000-0000-0000000000a5');
INSERT INTO public.push_devices (user_id, platform, device_token)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'ios', 'device-token-of-a-0001');

INSERT INTO public.posts (id, author_id, post_type, body, reaction_mode, comment_acceptance)
VALUES ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', 'soudan', 'Aの相談', 'want_comments', 'open');

-- Bのコメント2つ（運営が削除するもの・本人が削除するもの）。トリガーで、Aへの通知と配信待ちのプッシュができる
INSERT INTO public.comments (id, post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a2', '運営が削除するコメント'),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a2', '本人が削除するコメント');
-- Aは、1つ目のコメントを「自分だけ非表示」にしている
INSERT INTO public.hidden_items (user_id, target_type, target_id)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'comment', '00000000-0000-0000-0000-0000000000c1');

SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE comment_id = '00000000-0000-0000-0000-0000000000c1'),
  1, '（前提）コメントへの通知ができている');
SELECT is(
  (SELECT count(*)::int FROM public.push_deliveries d JOIN public.notifications n ON n.id = d.notification_id
   WHERE n.comment_id = '00000000-0000-0000-0000-0000000000c1' AND d.status = 'pending'),
  1, '（前提）配信待ちのプッシュができている');

-- === 運営が削除する ===
SELECT lives_ok(
  $$select public.moderation_apply('00000000-0000-0000-0000-0000000000a5', 'comment', '00000000-0000-0000-0000-0000000000c1', 'delete', '個人情報が含まれていたため削除')$$,
  '運営がコメントを削除できる');
SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE comment_id = '00000000-0000-0000-0000-0000000000c1'),
  0, '運営が削除したコメントの通知は、残らない');
SELECT is(
  (SELECT count(*)::int FROM public.push_deliveries d WHERE NOT EXISTS (SELECT 1 FROM public.notifications n WHERE n.id = d.notification_id)),
  0, '（参考）宛先のない配信待ちはない');
SELECT is(
  (SELECT count(*)::int FROM public.push_deliveries d JOIN public.notifications n ON n.id = d.notification_id
   WHERE n.comment_id = '00000000-0000-0000-0000-0000000000c1'),
  0, '運営が削除したコメントの配信待ちのプッシュは、残らない（削除のあとに届かない）');
SELECT is(
  (SELECT count(*)::int FROM public.hidden_items WHERE target_id = '00000000-0000-0000-0000-0000000000c1'),
  0, '本人だけの非表示の記録も残らない');
SELECT is(
  (SELECT count(*)::int FROM public.notifications
   WHERE notification_type = 'moderation' AND user_id = '00000000-0000-0000-0000-0000000000a2'),
  1, '運営からコメントした本人へのお知らせは、残る（理由を読める）');
SELECT is(
  (SELECT body FROM public.comments WHERE id = '00000000-0000-0000-0000-0000000000c1'),
  NULL, 'コメントの本文は消える（返信は残る）');

-- === 本人が削除する（これまでどおり） ===
SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE comment_id = '00000000-0000-0000-0000-0000000000c2'),
  1, '（前提）もう1つのコメントの通知がある');
SELECT lives_ok(
  $$select public.delete_comment('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000c2')$$,
  '本人がコメントを削除できる');
SELECT is(
  (SELECT count(*)::int FROM public.notifications WHERE comment_id = '00000000-0000-0000-0000-0000000000c2'),
  0, '本人が削除したコメントの通知も、残らない');

SELECT * FROM finish();
ROLLBACK;
