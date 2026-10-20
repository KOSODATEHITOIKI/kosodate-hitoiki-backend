-- Issue #21：削除済みデータが、バックアップからの復元で再公開されないようにする。
--
-- 投稿・コメント・アカウントの削除を、DBが自動で台帳に記録する（ID と時刻だけ。本文などは持たない）。
-- 復元のあとに replay_deletion_ledger() を実行すると、バックアップの取得後に削除されたものを再び削除する。
-- 台帳は、バックアップの保持期間（30日）より長く、35日間保持する。
-- 台帳は定期的に別の場所へも書き出す（バックアップの取得後の削除が、DBごと失われても追えるように）。

create table public.deletion_ledger (
  kind text not null check (kind in ('user', 'post', 'comment')),
  target_id uuid not null,
  deleted_at timestamptz not null default now(),
  primary key (kind, target_id)
);

comment on table public.deletion_ledger is
  '削除の台帳。復元のあとに削除をやり直すための、IDと時刻だけの記録（35日間保持）。service_role専用。';

create index deletion_ledger_deleted_at_idx on public.deletion_ledger (deleted_at);

alter table public.deletion_ledger enable row level security;
grant all on public.deletion_ledger to service_role;

-- 記録する。security definer：Auth（GoTrue）がユーザーを削除するとき（プロフィールのカスケード削除）も、
-- Authの権限では台帳に書き込めないため、所有者の権限で動かす。
create or replace function public.ledger_record_deletion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_table_name = 'posts' then
    insert into public.deletion_ledger (kind, target_id) values ('post', old.id)
    on conflict do nothing;
  elsif tg_table_name = 'profiles' then
    -- プロフィールの削除＝アカウントの削除（退会・Authの削除API）
    insert into public.deletion_ledger (kind, target_id) values ('user', old.id)
    on conflict do nothing;
  elsif tg_table_name = 'comments' then
    -- コメントのソフト削除（本文が消える）。投稿・アカウントの削除によるカスケードは、それぞれの台帳で追える。
    insert into public.deletion_ledger (kind, target_id) values ('comment', new.id)
    on conflict do nothing;
  end if;
  return null;
end;
$$;

create trigger posts_after_delete_ledger
  after delete on public.posts
  for each row execute function public.ledger_record_deletion();

create trigger profiles_after_delete_ledger
  after delete on public.profiles
  for each row execute function public.ledger_record_deletion();

create trigger comments_after_soft_delete_ledger
  after update of deleted_at on public.comments
  for each row when (old.deleted_at is null and new.deleted_at is not null)
  execute function public.ledger_record_deletion();

-- 復元のあとの再削除。何度実行しても安全（台帳にあるもので、いま存在するものだけを削除する）。
-- 手順：(1) バックアップを復元 (2) 取得後の台帳を取り込む (3) この関数を実行 (4) 結果を確認してから公開する。
create or replace function public.replay_deletion_ledger()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  n_users integer;
  n_posts integer;
  n_comments integer;
  n_hidden integer;
begin
  -- 他の人の「非表示」は外部キーがないので、消える投稿・コメントを指すものを先に消す。
  with gone_posts as (
    select p.id from public.posts p join public.deletion_ledger l on l.kind = 'post' and l.target_id = p.id
    union
    select p.id from public.posts p join public.deletion_ledger l on l.kind = 'user' and l.target_id = p.author_id
  ),
  gone_comments as (
    select c.id from public.comments c join public.deletion_ledger l on l.kind = 'user' and l.target_id = c.author_id
    union
    select c.id from public.comments c where c.post_id in (select id from gone_posts)
  )
  delete from public.hidden_items h
  where (h.target_type = 'post' and h.target_id in (select id from gone_posts))
     or (h.target_type = 'comment' and h.target_id in (select id from gone_comments));
  get diagnostics n_hidden = row_count;

  -- アカウント（プロフィール・投稿・コメント・共感・保存などは外部キーのカスケードで消える）
  delete from public.notifications where actor_id in (select target_id from public.deletion_ledger where kind = 'user');
  delete from auth.users where id in (select target_id from public.deletion_ledger where kind = 'user');
  get diagnostics n_users = row_count;

  -- 投稿（コメント・返信・共感・保存・通知はカスケードで消える）
  delete from public.posts where id in (select target_id from public.deletion_ledger where kind = 'post');
  get diagnostics n_posts = row_count;

  -- コメントのソフト削除。本文は、トリガーに頼らず、ここでも明示的に消す（復元の途中でトリガーが止まっていても）。
  update public.comments c
  set deleted_at = l.deleted_at, body = null
  from public.deletion_ledger l
  where l.kind = 'comment' and l.target_id = c.id and c.deleted_at is null;
  get diagnostics n_comments = row_count;

  return jsonb_build_object(
    'users', n_users, 'posts', n_posts, 'comments', n_comments, 'hidden_items', n_hidden
  );
end;
$$;

-- 別の場所へ書き出した台帳を取り込む（復元のあと、replay の前に実行する）。重複は無視する。
create or replace function public.import_deletion_ledger(p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  insert into public.deletion_ledger (kind, target_id, deleted_at)
  select r.kind, r.target_id, r.deleted_at
  from jsonb_to_recordset(p_rows) as r(kind text, target_id uuid, deleted_at timestamptz)
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- 保持期限（35日）を過ぎた台帳を、毎日の掃除で消す。
create or replace function public.purge_expired_records(p_now timestamptz default now())
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  n_actions integer;
  n_reports integer;
  n_reservations integer;
  n_keys integer;
  n_budget integer;
  n_events integer;
  n_ledger integer;
begin
  delete from public.moderation_actions where created_at < p_now - interval '1 year';
  get diagnostics n_actions = row_count;

  delete from public.reports where created_at < p_now - interval '1 year';
  get diagnostics n_reports = row_count;

  delete from public.nickname_reservations where reserved_until < p_now;
  get diagnostics n_reservations = row_count;

  delete from public.idempotency_keys where created_at < p_now - interval '24 hours';
  get diagnostics n_keys = row_count;

  delete from public.request_budget where window_start < p_now - interval '1 day';
  get diagnostics n_budget = row_count;

  delete from public.write_events where created_at < p_now - interval '30 days';
  get diagnostics n_events = row_count;

  delete from public.deletion_ledger where deleted_at < p_now - interval '35 days';
  get diagnostics n_ledger = row_count;

  return jsonb_build_object(
    'moderation_actions', n_actions,
    'reports', n_reports,
    'nickname_reservations', n_reservations,
    'idempotency_keys', n_keys,
    'request_budget', n_budget,
    'write_events', n_events,
    'deletion_ledger', n_ledger
  );
end;
$$;

-- === 権限：service_role専用 ===
do $$
declare
  fn text;
begin
  foreach fn in array array[
    'public.ledger_record_deletion()',
    'public.replay_deletion_ledger()',
    'public.import_deletion_ledger(jsonb)',
    'public.purge_expired_records(timestamptz)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;
