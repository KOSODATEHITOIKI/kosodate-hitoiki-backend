-- API（anon・authenticated）の権限の締め直し。deny-by-default：いったん全部外し、必要なものだけを明示して付ける。
--
-- 背景（点検で確認）：
--  - 未ログイン（anon）が posts テーブルを直接読めて author_id が取れた（公開用ビューは author_id を除いている）
--  - anon・authenticated が全テーブルに TRUNCATE・TRIGGER・REFERENCES を持っていた（TRUNCATEはRLSが効かない）
--  - 内部用のトリガー関数・補助関数を anon が実行できた
-- どの環境（ローカル・dev・prod）でも、プロジェクト作成時の「新しいテーブルを自動公開する」の設定に
-- 関わらず同じ状態に揃うよう、この移行で明示する。
-- 権限の一覧は supabase/tests/api_privileges_test.sql で固定している。新しいテーブル・ビュー・関数を
-- 追加するときは、必要な権限を同じ移行で付け、テストの期待値も更新する（公開しすぎるとテストが落ちる）。

-- === いったん全て外す ===
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

-- 今後このスキーマに作るオブジェクトを、anon・authenticated に自動で見せない。
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on functions from anon, authenticated;

-- === 未ログイン（anon）：公開マスタと公開ビューのみ ===
grant select on public.topics, public.reaction_types to anon;
grant select on public.public_posts, public.public_profiles to anon;

-- posts は列を絞る。author_id（利用者ID）・投稿の内部状態は、テーブルから直接は見せない。
-- public_posts（security_invoker）が参照する列と、RLSの判定に使う hidden_at だけ。
grant select (id, post_type, topic_id, body, reaction_mode, comment_acceptance, hidden_at,
  created_at, updated_at) on public.posts to anon;

-- === ログイン済み（authenticated）：読み取りはRLSが許すテーブルのみ ===
grant select on
  public.admin_users,
  public.profiles,
  public.nickname_reservations,
  public.topics,
  public.posts,
  public.comments,
  public.reaction_types,
  public.reports,
  public.moderation_actions,
  public.account_restrictions,
  public.notifications,
  public.app_settings,
  public.terms_acceptances,
  public.public_posts,
  public.public_profiles
to authenticated;

-- 自由記述を伴わない本人限定のトグル（CLAUDE.md）。TRUNCATE等は付けない。
grant select, insert, update, delete on
  public.reactions,
  public.saved_posts,
  public.hidden_items,
  public.muted_topics,
  public.muted_words,
  public.notification_settings,
  public.push_devices
to authenticated;

grant select, insert, delete on public.blocks to authenticated;

-- 通知は既読フラグの更新のみ。
grant update (is_read) on public.notifications to authenticated;

-- === 関数のEXECUTE ===
-- 外部（API）から呼ばせる関数だけを明示する。トリガー関数・create_profile・normalize_nickname等は
-- service_role（Edge Functions）とpostgresだけが実行できる。
grant execute on function public.post_comment_count(uuid) to anon, authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.is_restricted(uuid) to authenticated;
grant execute on function public.get_post_reaction_count(uuid) to authenticated;

grant execute on all functions in schema public to service_role;
