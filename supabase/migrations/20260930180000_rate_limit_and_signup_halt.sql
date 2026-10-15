-- Issue #18：登録直後の投稿・コメントの制限と、新規登録の一時停止。
--
-- 具体値は設定テーブル（app_settings）で、運営者がコード変更・再デプロイなしで変えられる。
-- 設定を変えられるのは運営者（二段階認証済み）だけで、変更の履歴を残す。

-- === 設定の初期値（承認済みの案：登録後24時間は、投稿1件・コメント3件。新規登録は停止しない） ===
insert into public.app_settings (key, value) values
  ('new_user_limit', '{"enabled": true, "window_hours": 24, "max_posts": 1, "max_comments": 3}'::jsonb),
  ('new_signup_halted', 'false'::jsonb)
on conflict (key) do nothing;

comment on table public.app_settings is
  '運営設定。new_user_limit：登録直後の投稿・コメントの制限（enabled・window_hours・max_posts・max_comments）。new_signup_halted：新規登録の一時停止（true/false）。変更はset_app_settingのみ（履歴はapp_settings_history）。';

-- === 設定の変更履歴（誰が・いつ・何を・前の値） ===
create table public.app_settings_history (
  id uuid primary key default gen_random_uuid(),
  key text not null,
  old_value jsonb,
  new_value jsonb not null,
  changed_by uuid not null references auth.users (id),
  changed_at timestamptz not null default now()
);

comment on table public.app_settings_history is
  '運営設定の変更履歴。運営者だけが参照できる。service_roleのDB関数だけが書き込む。';

create index app_settings_history_key_idx on public.app_settings_history (key, changed_at desc);

alter table public.app_settings_history enable row level security;

create policy app_settings_history_select_admin
  on public.app_settings_history
  for select
  to authenticated
  using (public.is_admin());

grant select on public.app_settings_history to authenticated;
grant all on public.app_settings_history to service_role;

-- === 書き込みの記録（削除しても回数が戻らないよう、投稿・コメントとは別に持つ） ===
create table public.write_events (
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('post', 'comment')),
  created_at timestamptz not null default now()
);

comment on table public.write_events is
  '登録直後の制限の回数に使う、投稿・コメントの作成の記録。投稿・コメントを削除しても残る。30日を過ぎたものは次回の作成時に削除する。service_role専用。';

create index write_events_user_kind_idx on public.write_events (user_id, kind, created_at);

alter table public.write_events enable row level security;
-- ポリシーなし（anon・authenticatedは参照も書き込みもできない）。

grant all on public.write_events to service_role;

-- === 設定の取得 ===
create or replace function public.app_setting(p_key text)
returns jsonb
language sql
stable
set search_path = public
as $$
  select value from public.app_settings where key = p_key;
$$;

-- === 新規登録の停止：新しいアカウント（auth.users）の作成そのものを止める（Authのフック） ===
-- before_user_created フックは、メール・Google・Appleのどの経路でも、作成の前に呼ばれる。
-- 既存の利用者のログイン（作成ではない）には影響しない。
-- フックの設定（config.toml／クラウドはダッシュボード）が効いていない場合に備えて、
-- プロフィールの作成（create_profile）でも止める。
create or replace function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
begin
  if coalesce(public.app_setting('new_signup_halted') = 'true'::jsonb, false) then
    return jsonb_build_object(
      'error', jsonb_build_object(
        'http_code', 429,
        'message', '現在、新規登録を一時的にお休みしています。しばらくしてからもう一度お試しください。'
      )
    );
  end if;
  return '{}'::jsonb;
end;
$$;

-- フックを呼ぶのはAuthのロール（supabase_auth_admin）だけ。ほかのロールからは呼べない。
revoke all on function public.hook_before_user_created(jsonb) from public, anon, authenticated;
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
grant execute on function public.app_setting(text) to supabase_auth_admin;
grant select on public.app_settings to supabase_auth_admin;

-- app_settings のRLSは、運営者（二段階認証済み）だけが参照できる。Authのフックは、RLSを迂回する
-- security definer の下の関数ではなく、参照権限とポリシーで読む。supabase_auth_admin 用の参照ポリシー。
create policy app_settings_select_auth_hook
  on public.app_settings
  for select
  to supabase_auth_admin
  using (key = 'new_signup_halted');

-- === 登録直後の制限 ===
-- 運営者は対象外。制限が無効、または登録から時間が経っていれば何もしない。
-- 利用者単位の排他ロックで、同時の作成でも上限を超えない。
-- 超えた場合は、制限が解ける日時（窓の終わり）を DETAIL に入れて RATE_LIMITED を返す。
create or replace function public.enforce_new_user_limit(p_user_id uuid, p_kind text)
returns void
language plpgsql
set search_path = public
as $$
declare
  cfg jsonb := public.app_setting('new_user_limit');
  registered timestamptz;
  window_end timestamptz;
  max_count integer;
  used integer;
begin
  if cfg is null or coalesce((cfg ->> 'enabled')::boolean, false) is not true then
    return;
  end if;
  if exists (select 1 from public.admin_users where user_id = p_user_id) then
    return;
  end if;

  select created_at into registered from public.profiles where id = p_user_id;
  if registered is null then
    return; -- プロフィールの有無は assert_can_write が確認する
  end if;

  window_end := registered + make_interval(hours => (cfg ->> 'window_hours')::integer);
  if now() >= window_end then
    return;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('write_limit:' || p_user_id::text, 0));

  delete from public.write_events
  where user_id = p_user_id and created_at < now() - interval '30 days';

  max_count := case p_kind
    when 'post' then (cfg ->> 'max_posts')::integer
    else (cfg ->> 'max_comments')::integer
  end;

  select count(*) into used from public.write_events
  where user_id = p_user_id and kind = p_kind and created_at >= registered;

  if used >= max_count then
    raise exception 'RATE_LIMITED' using errcode = 'P0001', detail = window_end::text;
  end if;

  insert into public.write_events (user_id, kind) values (p_user_id, p_kind);
end;
$$;

-- === 投稿・コメントの作成に、制限を組み込む ===
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

  -- 再送（上のreplay）は数えない。ここまで来たものだけが、1回の作成として数えられる。
  perform public.enforce_new_user_limit(p_user_id, 'post');

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

  -- 拒否される条件（上）を先に確かめ、保存できるときだけ回数として数える。
  perform public.enforce_new_user_limit(p_user_id, 'comment');

  insert into public.comments (post_id, author_id, parent_comment_id, body)
  values (p_post_id, p_user_id, p_parent_comment_id, p_body)
  returning id, created_at into new_comment;

  result := jsonb_build_object('id', new_comment.id, 'created_at', new_comment.created_at);
  perform public.finish_idempotency_key(p_user_id, 'comment.create', p_idempotency_key, result);
  return result;
end;
$$;

-- === プロフィールの作成：新規登録の停止中は、新しく作らない（既存の再送は通す） ===
create or replace function public.create_profile(
  p_user_id uuid,
  p_nickname text,
  p_bio text,
  p_child_age_range text,
  p_icon_key text,
  p_terms_version text
)
returns text
language plpgsql
set search_path = public
as $$
declare
  inserted integer;
  result text := 'created';
begin
  -- 応答が届かず再送された同じ登録（作成済み）は、停止中でも成功を返す。新しい作成だけを止める。
  if not exists (select 1 from public.profiles where id = p_user_id)
     and coalesce(public.app_setting('new_signup_halted') = 'true'::jsonb, false) then
    raise exception 'SIGNUP_HALTED' using errcode = 'P0001';
  end if;

  insert into public.profiles (id, nickname, bio, child_age_range, icon_key)
  values (p_user_id, p_nickname, p_bio, p_child_age_range, p_icon_key)
  on conflict (id) do nothing;

  get diagnostics inserted = row_count;

  if inserted = 0 then
    if exists (
      select 1 from public.profiles
      where id = p_user_id and normalized_nickname = public.normalize_nickname(p_nickname)
    ) then
      result := 'exists';
    else
      return 'conflict';
    end if;
  end if;

  insert into public.terms_acceptances (user_id, terms_version)
  values (p_user_id, p_terms_version)
  on conflict do nothing;

  insert into public.notification_settings (user_id)
  values (p_user_id)
  on conflict do nothing;

  return result;
end;
$$;

-- === 運営者による設定の変更（値の形を検証し、履歴を残す） ===
-- 運営者の登録をDBでも確認する（二段階認証の確認は、Edge Functionで行う）。
create or replace function public.set_app_setting(p_admin_id uuid, p_key text, p_value jsonb)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  old jsonb;
begin
  if not exists (select 1 from public.admin_users where user_id = p_admin_id) then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;

  if p_key = 'new_signup_halted' then
    if jsonb_typeof(p_value) <> 'boolean' then
      raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
    end if;
  elsif p_key = 'new_user_limit' then
    if jsonb_typeof(p_value) <> 'object'
       or jsonb_typeof(p_value -> 'enabled') is distinct from 'boolean'
       or jsonb_typeof(p_value -> 'window_hours') is distinct from 'number'
       or jsonb_typeof(p_value -> 'max_posts') is distinct from 'number'
       or jsonb_typeof(p_value -> 'max_comments') is distinct from 'number'
       or (select count(*) from jsonb_object_keys(p_value)) <> 4
       or (p_value ->> 'window_hours') !~ '^[0-9]+$'
       or (p_value ->> 'max_posts') !~ '^[0-9]+$'
       or (p_value ->> 'max_comments') !~ '^[0-9]+$'
       or (p_value ->> 'window_hours')::integer not between 1 and 720
       or (p_value ->> 'max_posts')::integer not between 0 and 1000
       or (p_value ->> 'max_comments')::integer not between 0 and 1000 then
      raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
    end if;
  else
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001'; -- 未知のキーは作らせない
  end if;

  -- 同じ設定の同時変更を直列化し、変更前の値を履歴に残す。
  perform pg_advisory_xact_lock(hashtextextended('app_setting:' || p_key, 0));
  select value into old from public.app_settings where key = p_key;

  insert into public.app_settings (key, value, updated_by)
  values (p_key, p_value, p_admin_id)
  on conflict (key) do update
    set value = excluded.value, updated_by = excluded.updated_by;

  insert into public.app_settings_history (key, old_value, new_value, changed_by)
  values (p_key, old, p_value, p_admin_id);

  return jsonb_build_object('key', p_key, 'value', p_value);
end;
$$;

-- === 権限：service_role専用（フック用の関数を除く） ===
do $$
declare
  fn text;
begin
  foreach fn in array array[
    'public.enforce_new_user_limit(uuid, text)',
    'public.set_app_setting(uuid, text, jsonb)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
  -- 再定義した関数は、元の権限（service_roleだけ）を保つ。create or replaceは権限を変えないが、明示する。
  revoke all on function public.create_post(uuid, text, smallint, text, text, text) from public, anon, authenticated;
  revoke all on function public.create_comment(uuid, uuid, uuid, text, text) from public, anon, authenticated;
  revoke all on function public.create_profile(uuid, text, text, text, text, text) from public, anon, authenticated;
  revoke all on function public.app_setting(text) from public, anon, authenticated;
  grant execute on function public.app_setting(text) to service_role, supabase_auth_admin;
end;
$$;
