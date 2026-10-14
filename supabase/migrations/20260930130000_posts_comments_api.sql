-- Issue #13：投稿・コメント・返信のAPI（Edge Functionsから呼ぶDB関数）と、公開ビューへのニックネーム結合。
--
-- 書き込みはEdge Functions（service_role）経由のみ。ここで作る関数はservice_role専用で、
-- 権限・受付状態・ブロック・利用停止の確認と保存を1トランザクションにまとめる。
-- anon・authenticatedにはEXECUTEを付けない（deny-by-default。supabase/tests/api_privileges_test.sql）。
-- エラーは P0001 で、メッセージに内部コードを入れる（Edge Function側が対応するHTTPコードへ変換する）。

-- === 「編集済み」の判定用 ===
-- updated_at は反応モードの変更などでも変わるため、本文が実際に変わったときだけ設定する専用の列を持つ。
alter table public.posts add column edited_at timestamptz;
alter table public.comments add column edited_at timestamptz;

-- === 文字数：絵文字等を1文字として数える（Edge Functionで厳密に検証し、DBは緩い上限） ===
-- 1文字が最大7コードポイント程度になりうるため、1,000文字→7,000、500文字→3,500。
alter table public.posts drop constraint posts_body_check;
alter table public.posts
  add constraint posts_body_length check (char_length(body) between 1 and 7000);

alter table public.comments drop constraint comments_body_check;
alter table public.comments
  add constraint comments_body_length check (char_length(body) <= 3500);

-- === 再送で重複させない（Idempotency-Key、利用者ごと・24時間） ===
create table public.idempotency_keys (
  user_id uuid not null references auth.users (id) on delete cascade,
  endpoint text not null,
  key text not null check (char_length(key) between 1 and 64),
  response jsonb,
  created_at timestamptz not null default now(),
  primary key (user_id, endpoint, key)
);

comment on table public.idempotency_keys is
  '作成系APIの再送防止。同じキーの再送は最初の結果を返す。service_role専用。24時間を過ぎたものは次回の呼び出しで削除する。';

create index idempotency_keys_user_created_idx on public.idempotency_keys (user_id, created_at);

alter table public.idempotency_keys enable row level security;
-- ポリシーなし（anon・authenticatedは参照も書き込みもできない）。

grant all on public.idempotency_keys to service_role;

-- === 公開ビュー ===
-- 公開プロフィールは、自分自身と、公開中の投稿の投稿者に限る（投稿のない登録者の一覧を出さない）。
-- ログイン済みには、公開中のコメントの投稿者も含める（コメントは会員限定のため）。
create or replace view public.public_profiles as
select p.id, p.nickname, p.icon_key, p.avatar_path
from public.profiles p
where p.id = auth.uid()
  or exists (
    select 1 from public.posts po
    where po.author_id = p.id and po.hidden_at is null
  )
  or (
    auth.uid() is not null
    and exists (
      select 1 from public.comments c
      where c.author_id = p.id and c.deleted_at is null and c.hidden_at is null
    )
  );

-- 投稿者の表示情報（ニックネーム・アイコン）。未ログインは posts.author_id を読めないため、
-- owner権限のこの関数で結合する（利用者IDは返さない）。公開中の投稿に限る。
create or replace function public.post_author_profile(p_post_id uuid)
returns table (nickname text, icon_key text, avatar_path text)
language sql
stable
security definer
set search_path = public
as $$
  select pr.nickname, pr.icon_key, pr.avatar_path
  from public.posts p
  join public.profiles pr on pr.id = p.author_id
  where p.id = p_post_id and p.hidden_at is null;
$$;

-- 投稿一覧：投稿者のニックネーム・アイコンを結合する。利用者ID（author_id）は出さない。
create or replace view public.public_posts
  with (security_invoker = true) as
select
  p.id,
  p.post_type,
  p.topic_id,
  p.body,
  p.reaction_mode,
  p.comment_acceptance,
  p.created_at,
  p.updated_at,
  public.post_comment_count(p.id) as comment_count,
  p.edited_at,
  a.nickname as author_nickname,
  a.icon_key as author_icon_key,
  a.avatar_path as author_avatar_path
from public.posts p
left join lateral public.post_author_profile(p.id) a on true
where p.hidden_at is null;

comment on view public.public_posts is
  '一覧・検索で使う公開投稿ビュー。共感件数・通報情報・投稿者の利用者IDを含まない。';

-- コメント一覧（ログイン必須）：削除済みは本文なし、投稿者のニックネームを結合する。
-- 一時非表示・親投稿が一時非表示のコメントは、commentsのRLSで除外される（運営者を除く）。
create view public.member_comments
  with (security_invoker = true) as
select
  c.id,
  c.post_id,
  c.parent_comment_id,
  c.author_id,
  c.body,
  (c.deleted_at is not null) as is_deleted,
  c.created_at,
  c.edited_at,
  pr.nickname as author_nickname,
  pr.icon_key as author_icon_key,
  pr.avatar_path as author_avatar_path
from public.comments c
left join public.public_profiles pr on pr.id = c.author_id;

comment on view public.member_comments is
  'ログイン済み利用者向けのコメント一覧。削除済みは本文がnull。古い順の並びはクライアントが created_at で指定する。';

grant select on public.member_comments to authenticated;

-- 未ログインには public_profiles（利用者IDを含む）を公開しない。ニックネームは public_posts から取れる。
revoke select on public.public_profiles from anon;
grant select (edited_at) on public.posts to anon;

-- === DB関数 ===

-- 利用者の前提確認（プロフィールがある・利用停止中でない）。
create or replace function public.assert_can_write(p_user_id uuid)
returns void
language plpgsql
set search_path = public
as $$
begin
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'PROFILE_REQUIRED' using errcode = 'P0001';
  end if;
  if public.is_restricted(p_user_id) then
    raise exception 'RESTRICTED' using errcode = 'P0001';
  end if;
end;
$$;

-- Idempotency-Keyを確保する。既に処理済みなら、その結果を返す（戻り値がnullでなければ再送）。
create or replace function public.claim_idempotency_key(p_user_id uuid, p_endpoint text, p_key text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  inserted integer;
  saved jsonb;
begin
  if p_key is null then
    return null;
  end if;

  delete from public.idempotency_keys
  where user_id = p_user_id and created_at < now() - interval '24 hours';

  -- 同じキーを同時に処理する別トランザクションがあれば、その完了を待ってから判定される。
  insert into public.idempotency_keys (user_id, endpoint, key)
  values (p_user_id, p_endpoint, p_key)
  on conflict do nothing;
  get diagnostics inserted = row_count;

  if inserted = 1 then
    return null;
  end if;

  select response into saved
  from public.idempotency_keys
  where user_id = p_user_id and endpoint = p_endpoint and key = p_key;
  return coalesce(saved, '{}'::jsonb);
end;
$$;

create or replace function public.finish_idempotency_key(
  p_user_id uuid, p_endpoint text, p_key text, p_response jsonb
)
returns void
language plpgsql
set search_path = public
as $$
begin
  if p_key is not null then
    update public.idempotency_keys set response = p_response
    where user_id = p_user_id and endpoint = p_endpoint and key = p_key;
  end if;
end;
$$;

-- 投稿の作成
create or replace function public.create_post(
  p_user_id uuid,
  p_post_type text,
  p_topic_id smallint,
  p_body text,
  p_reaction_mode text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  replay jsonb;
  new_post record;
  result jsonb;
begin
  replay := public.claim_idempotency_key(p_user_id, 'post.create', p_idempotency_key);
  if replay is not null then
    return replay;
  end if;

  perform public.assert_can_write(p_user_id);

  if p_topic_id is not null
     and not exists (select 1 from public.topics where id = p_topic_id and is_active) then
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
  end if;

  insert into public.posts (author_id, post_type, topic_id, body, reaction_mode, comment_acceptance)
  values (
    p_user_id, p_post_type, p_topic_id, p_body, p_reaction_mode,
    case when p_reaction_mode = 'want_comments' then 'open' end
  )
  returning id, created_at into new_post;

  result := jsonb_build_object('id', new_post.id, 'created_at', new_post.created_at);
  perform public.finish_idempotency_key(p_user_id, 'post.create', p_idempotency_key, result);
  return result;
end;
$$;

-- 投稿本文の編集（本人のみ。本文が変わったときだけ「編集済み」にする）
create or replace function public.update_post_body(p_user_id uuid, p_post_id uuid, p_body text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  target record;
  new_edited_at timestamptz;
begin
  select author_id, body, edited_at into target
  from public.posts where id = p_post_id for update;

  if not found then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if target.author_id <> p_user_id then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;
  if public.is_restricted(p_user_id) then
    raise exception 'RESTRICTED' using errcode = 'P0001';
  end if;

  new_edited_at := target.edited_at;
  if target.body is distinct from p_body then
    new_edited_at := now();
    update public.posts set body = p_body, edited_at = new_edited_at where id = p_post_id;
  end if;

  return jsonb_build_object('id', p_post_id, 'edited_at', new_edited_at);
end;
$$;

-- 投稿の削除（本人のみ）。コメント・返信・共感・保存・通知は外部キーで一緒に消える。
-- 論理参照（hidden_items）は外部キーがないので、ここで消す。通報の記録は保持期間まで残す。
create or replace function public.delete_post(p_user_id uuid, p_post_id uuid)
returns void
language plpgsql
set search_path = public
as $$
declare
  owner uuid;
begin
  select author_id into owner from public.posts where id = p_post_id for update;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if owner <> p_user_id then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;

  delete from public.hidden_items
  where (target_type = 'post' and target_id = p_post_id)
     or (target_type = 'comment'
         and target_id in (select id from public.comments where post_id = p_post_id));

  delete from public.posts where id = p_post_id;
end;
$$;

-- 反応モード・受付状態の変更（本人のみ）。コメント作成とは投稿行のロックで直列化する。
create or replace function public.set_post_reaction_mode(
  p_user_id uuid, p_post_id uuid, p_mode text, p_acceptance text
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  target record;
  new_acceptance text;
begin
  if p_mode not in ('quiet_support', 'want_comments')
     or (p_acceptance is not null and p_acceptance not in ('open', 'closed')) then
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
  end if;

  select author_id, comment_acceptance into target
  from public.posts where id = p_post_id for update;

  if not found then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if target.author_id <> p_user_id then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;

  if p_mode = 'quiet_support' then
    -- 受付状態は「話を聞きたい」のときだけ意味を持つ。
    if p_acceptance is not null then
      raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
    end if;
    new_acceptance := null;
  else
    new_acceptance := coalesce(p_acceptance, target.comment_acceptance, 'open');
  end if;

  update public.posts
  set reaction_mode = p_mode, comment_acceptance = new_acceptance
  where id = p_post_id;

  return jsonb_build_object('reaction_mode', p_mode, 'comment_acceptance', new_acceptance);
end;
$$;

-- コメント・返信の作成
create or replace function public.create_comment(
  p_user_id uuid,
  p_post_id uuid,
  p_parent_comment_id uuid,
  p_body text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  replay jsonb;
  target record;
  parent record;
  new_comment record;
  result jsonb;
begin
  replay := public.claim_idempotency_key(p_user_id, 'comment.create', p_idempotency_key);
  if replay is not null then
    return replay;
  end if;

  perform public.assert_can_write(p_user_id);

  -- 投稿行を共有ロックする。受付状態の変更（for update）と同時に走っても、
  -- 変更が確定してから判定され、受付終了後に新規コメントが保存されることはない。
  select author_id, reaction_mode, comment_acceptance, hidden_at into target
  from public.posts where id = p_post_id for share;

  if not found or target.hidden_at is not null then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if target.reaction_mode <> 'want_comments' or target.comment_acceptance is distinct from 'open' then
    raise exception 'COMMENTS_CLOSED' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from public.blocks where blocker_id = target.author_id and blocked_id = p_user_id
  ) then
    raise exception 'BLOCKED' using errcode = 'P0001';
  end if;

  if p_parent_comment_id is not null then
    select post_id, author_id, deleted_at, hidden_at into parent
    from public.comments where id = p_parent_comment_id;

    if not found or parent.post_id <> p_post_id
       or parent.deleted_at is not null or parent.hidden_at is not null then
      raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
    end if;
    if exists (
      select 1 from public.blocks where blocker_id = parent.author_id and blocked_id = p_user_id
    ) then
      raise exception 'BLOCKED' using errcode = 'P0001';
    end if;
  end if;

  insert into public.comments (post_id, author_id, parent_comment_id, body)
  values (p_post_id, p_user_id, p_parent_comment_id, p_body)
  returning id, created_at into new_comment;

  result := jsonb_build_object('id', new_comment.id, 'created_at', new_comment.created_at);
  perform public.finish_idempotency_key(p_user_id, 'comment.create', p_idempotency_key, result);
  return result;
end;
$$;

-- コメント本文の編集（本人のみ。受付終了後も可）
create or replace function public.update_comment_body(p_user_id uuid, p_comment_id uuid, p_body text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  target record;
  new_edited_at timestamptz;
begin
  select c.author_id, c.body, c.edited_at, c.deleted_at, c.hidden_at, p.hidden_at as post_hidden_at
  into target
  from public.comments c
  join public.posts p on p.id = c.post_id
  where c.id = p_comment_id
  for update of c;

  if not found or target.deleted_at is not null
     or target.hidden_at is not null or target.post_hidden_at is not null then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if target.author_id <> p_user_id then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;
  if public.is_restricted(p_user_id) then
    raise exception 'RESTRICTED' using errcode = 'P0001';
  end if;

  new_edited_at := target.edited_at;
  if target.body is distinct from p_body then
    new_edited_at := now();
    update public.comments set body = p_body, edited_at = new_edited_at where id = p_comment_id;
  end if;

  return jsonb_build_object('id', p_comment_id, 'edited_at', new_edited_at);
end;
$$;

-- コメントの削除（本人のみ。ソフト削除。返信は残る）
create or replace function public.delete_comment(p_user_id uuid, p_comment_id uuid)
returns void
language plpgsql
set search_path = public
as $$
declare
  target record;
begin
  select author_id, deleted_at into target
  from public.comments where id = p_comment_id for update;

  if not found or target.deleted_at is not null then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if target.author_id <> p_user_id then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;

  -- 本文は消える（comments_before_soft_delete トリガー）。本人だけの非表示と通知の残骸も消す。
  update public.comments set deleted_at = now() where id = p_comment_id;
  delete from public.hidden_items where target_type = 'comment' and target_id = p_comment_id;
  delete from public.notifications where comment_id = p_comment_id;
end;
$$;

-- === 権限 ===
-- 投稿者の表示情報（public_postsが使う）。
revoke all on function public.post_author_profile(uuid) from public, anon, authenticated;
grant execute on function public.post_author_profile(uuid) to anon, authenticated, service_role;

-- 書き込み系はservice_role専用。
do $$
declare
  fn text;
begin
  foreach fn in array array[
    'public.assert_can_write(uuid)',
    'public.claim_idempotency_key(uuid, text, text)',
    'public.finish_idempotency_key(uuid, text, text, jsonb)',
    'public.create_post(uuid, text, smallint, text, text, text)',
    'public.update_post_body(uuid, uuid, text)',
    'public.delete_post(uuid, uuid)',
    'public.set_post_reaction_mode(uuid, uuid, text, text)',
    'public.create_comment(uuid, uuid, uuid, text, text)',
    'public.update_comment_body(uuid, uuid, text)',
    'public.delete_comment(uuid, uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;
