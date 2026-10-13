-- トリガー・業務ルールの検証（docs/バックエンド設計.md・docs/スキーマ定義.md）。

BEGIN;
SELECT plan(14);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000a1'), -- 投稿者
  ('00000000-0000-0000-0000-0000000000a2'), -- 通報者1
  ('00000000-0000-0000-0000-0000000000a3'), -- 通報者2
  ('00000000-0000-0000-0000-0000000000a4'), -- 通報者3
  ('00000000-0000-0000-0000-0000000000a5'), -- 運営者
  ('00000000-0000-0000-0000-0000000000a6'); -- コメント投稿者

INSERT INTO public.admin_users (user_id) VALUES ('00000000-0000-0000-0000-0000000000a5');

INSERT INTO public.posts (id, author_id, post_type, body) VALUES
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a1', 'guchi', '本文');

-- --- ニックネーム正規化・重複判定 ---
-- 'Hanako'（半角）と 'ｈａｎａｋｏ'（全角小文字）はNFKC正規化＋大文字小文字統一で同一視される。
INSERT INTO public.profiles (id, nickname) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'Hanako');

SELECT throws_ok(
  $$insert into public.profiles (id, nickname) values ('00000000-0000-0000-0000-0000000000a2', 'ｈａｎａｋｏ')$$,
  '23505',
  null,
  '全角半角・大文字小文字が同一視され、重複ニックネームは一意制約で拒否される'
);

-- 前後の空白も同一視される
SELECT is(
  public.normalize_nickname('  Hanako  '),
  public.normalize_nickname('Hanako'),
  '前後の空白は正規化で無視される'
);

-- 初回の変更は制限しない（登録直後の誤字修正を許す）
SELECT lives_ok(
  $$update public.profiles set nickname = 'ハナコ' where id = '00000000-0000-0000-0000-0000000000a1'$$,
  '登録直後でも、初回のニックネーム変更は許可される'
);

-- 2回目以降は前回の変更から30日空ける
SELECT throws_ok(
  $$update public.profiles set nickname = 'ハナ' where id = '00000000-0000-0000-0000-0000000000a1'$$,
  'P0001',
  'ニックネームは30日に1回まで変更できます',
  '変更から30日以内の再変更は拒否される'
);

-- --- コメントの親子関係検証 ---
INSERT INTO public.comments (id, post_id, author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a6', '親コメント');

SELECT lives_ok(
  $$insert into public.comments (post_id, author_id, parent_comment_id, body)
    values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000c1', '返信')$$,
  '親コメントへの返信は許可される'
);

SELECT throws_ok(
  $$insert into public.comments (post_id, author_id, parent_comment_id, body)
    values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a1',
      (select id from public.comments where body = '返信'), '返信への返信')$$,
  'P0001',
  '返信への返信はできません',
  '返信への返信は拒否される（1段階のみ）'
);

-- 削除（ソフト削除）で本文がクリアされる
UPDATE public.comments SET deleted_at = now() WHERE id = '00000000-0000-0000-0000-0000000000c1';

SELECT is(
  (SELECT body FROM public.comments WHERE id = '00000000-0000-0000-0000-0000000000c1'),
  NULL,
  '削除済みコメントは本文がクリアされる（「削除済み」表示に置換）'
);

-- --- 通報の自動一時非表示 ---
INSERT INTO public.reports (reporter_id, target_type, target_id, reason) VALUES
  ('00000000-0000-0000-0000-0000000000a2', 'post', '00000000-0000-0000-0000-0000000000f1', 'other'),
  ('00000000-0000-0000-0000-0000000000a3', 'post', '00000000-0000-0000-0000-0000000000f1', 'other');

SELECT is(
  (SELECT hidden_at FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000f1'),
  NULL,
  '通報者が2人まではまだ自動一時非表示にならない'
);

INSERT INTO public.reports (reporter_id, target_type, target_id, reason) VALUES
  ('00000000-0000-0000-0000-0000000000a4', 'post', '00000000-0000-0000-0000-0000000000f1', 'other');

SELECT isnt(
  (SELECT hidden_at FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000f1'),
  NULL,
  '異なる通報者が3人に達すると自動で一時非表示になる'
);

-- 同一通報者・同一対象の未対応通報は重複できない
SELECT throws_ok(
  $$insert into public.reports (reporter_id, target_type, target_id, reason)
    values ('00000000-0000-0000-0000-0000000000a2', 'post', '00000000-0000-0000-0000-0000000000f1', 'other')$$,
  '23505',
  null,
  '同一通報者・同一対象の未対応通報は重複登録できない'
);

-- 運営者が再表示すると、未対応通報が解消され一時非表示が解除される
INSERT INTO public.moderation_actions (admin_id, target_type, target_id, action, reason) VALUES
  ('00000000-0000-0000-0000-0000000000a5', 'post', '00000000-0000-0000-0000-0000000000f1', 'unhide', '誤検知');

SELECT is(
  (SELECT hidden_at FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000f1'),
  NULL,
  '運営者の unhide 操作で一時非表示が解除される'
);

SELECT is(
  (SELECT count(*)::int FROM public.reports
    WHERE target_id = '00000000-0000-0000-0000-0000000000f1' AND resolved_at IS NULL),
  0,
  '再表示後は未対応通報が0件になる（再集計されない）'
);

-- 再表示後、同一通報者が改めて通報できる（新しい未対応行として）
SELECT lives_ok(
  $$insert into public.reports (reporter_id, target_type, target_id, reason)
    values ('00000000-0000-0000-0000-0000000000a2', 'post', '00000000-0000-0000-0000-0000000000f1', 'other')$$,
  '再表示後は同じ通報者が改めて通報できる'
);

-- 再表示済みの対象は、新たな通報が3人に達しても自動で再び非表示にならない
INSERT INTO public.reports (reporter_id, target_type, target_id, reason) VALUES
  ('00000000-0000-0000-0000-0000000000a3', 'post', '00000000-0000-0000-0000-0000000000f1', 'other'),
  ('00000000-0000-0000-0000-0000000000a4', 'post', '00000000-0000-0000-0000-0000000000f1', 'other');

SELECT is(
  (SELECT hidden_at FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000f1'),
  NULL,
  '再表示後に新たな通報が3人分集まっても再び自動非表示にならない'
);

SELECT * FROM finish();
ROLLBACK;
