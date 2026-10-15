-- 公開前レビューの指摘への対処。
--   (3) 画像の削除待ちを永続化する（削除に失敗しても、成功するまで再試行できる）
--   (4) 外部API（送信前チェック）を呼ぶ前の、操作資格・頻度制限・利用者ごとのリクエスト上限
--   (2) 退会の本人確認を、操作中のセッションに結び付ける

-- === (3) 画像の削除待ち ===
-- アカウント画像のパスがプロフィールから外れる（差し替え・削除・イラストへの変更・退会）と、
-- DBのトリガーが、同じトランザクションで削除待ちに記録する。Storageの削除はAPI経由で、あとから行う。
-- 削除に失敗しても記録が残るので、成功するまで再試行できる（URLを知る人が見られる画像を残さない）。
create table public.pending_storage_deletions (
  bucket text not null default 'avatars',
  path text not null,
  attempts integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  primary key (bucket, path)
);

comment on table public.pending_storage_deletions is
  'Storageから削除すべきファイルの待ち行列。削除に成功したら行を消す。last_errorはコードだけ。service_role専用。';

alter table public.pending_storage_deletions enable row level security;
grant all on public.pending_storage_deletions to service_role;

-- security definer：Auth（GoTrue）がユーザーを削除すると、プロフィールのカスケード削除でこのトリガーが
-- Authの権限（supabase_auth_admin）で動く。その権限には削除待ちへの書き込みがないため、所有者の権限で動かす。
create or replace function public.profiles_queue_avatar_deletion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.avatar_path is not null and (tg_op = 'DELETE' or old.avatar_path is distinct from new.avatar_path) then
    insert into public.pending_storage_deletions (bucket, path)
    values ('avatars', old.avatar_path)
    on conflict do nothing;
  end if;
  return null;
end;
$$;

create trigger profiles_after_avatar_change_queue
  after update of avatar_path on public.profiles
  for each row execute function public.profiles_queue_avatar_deletion();

create trigger profiles_after_delete_queue_avatar
  after delete on public.profiles
  for each row execute function public.profiles_queue_avatar_deletion();

-- 削除待ちを取り出す。古い順。
create or replace function public.claim_storage_deletions(p_limit integer default 20)
returns table (bucket text, path text)
language sql
set search_path = public
as $$
  select d.bucket, d.path
  from public.pending_storage_deletions d
  order by d.created_at
  limit greatest(1, least(p_limit, 200));
$$;

-- 結果の記録。成功したら行を消す。失敗したら回数を増やす（エラーはコードだけ）。
create or replace function public.finish_storage_deletion(p_bucket text, p_path text, p_ok boolean, p_error text default null)
returns void
language plpgsql
set search_path = public
as $$
begin
  if p_ok then
    delete from public.pending_storage_deletions where bucket = p_bucket and path = p_path;
  else
    update public.pending_storage_deletions
    set attempts = attempts + 1,
        last_error = case when p_error ~ '^[A-Za-z0-9_]{1,40}$' then p_error else 'UNKNOWN' end
    where bucket = p_bucket and path = p_path;
  end if;
end;
$$;

-- === (4) 外部APIを呼ぶ前の確認 ===
-- 利用者ごとのリクエスト数（固定の窓）。送信前チェック（外部API）を呼ぶ操作が対象。
create table public.request_budget (
  user_id uuid not null references auth.users (id) on delete cascade,
  bucket text not null,
  window_start timestamptz not null,
  request_count integer not null default 0,
  primary key (user_id, bucket, window_start)
);

comment on table public.request_budget is
  '利用者ごとのリクエスト数（10分の窓）。外部APIを呼ぶ操作の連打を止める。service_role専用。1日を過ぎた行は毎日削除する。';

alter table public.request_budget enable row level security;
grant all on public.request_budget to service_role;

-- 登録直後の制限の判定（数えずに、超えていれば解除の日時を返す）。enforce_new_user_limit と共通。
create or replace function public.new_user_limit_status(p_user_id uuid, p_kind text)
returns timestamptz
language plpgsql
stable
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
    return null;
  end if;
  if exists (select 1 from public.admin_users where user_id = p_user_id) then
    return null;
  end if;
  select created_at into registered from public.profiles where id = p_user_id;
  if registered is null then
    return null;
  end if;
  window_end := registered + make_interval(hours => (cfg ->> 'window_hours')::integer);
  if now() >= window_end then
    return null;
  end if;
  max_count := case p_kind
    when 'post' then (cfg ->> 'max_posts')::integer
    else (cfg ->> 'max_comments')::integer
  end;
  select count(*) into used from public.write_events
  where user_id = p_user_id and kind = p_kind and created_at >= registered;
  return case when used >= max_count then window_end end;
end;
$$;

-- 外部API（送信前チェック）を呼ぶ前に、必ず通す確認。
--   kind: post・comment（作成）／edit（編集）／profile（プロフィール系）／image（画像）
--   1. 操作の資格（利用停止中・プロフィール未登録は、ここで止める。profile・imageは対象外）
--   2. 登録直後の上限（作成だけ。数えずに判定する。実際の回数は保存時に数える）
--   （完了済みのIdempotency-Keyの再送は、2の対象にしない）
--   3. 利用者ごとのリクエスト上限（10分あたり：テキスト30回・画像10回。暫定値）
-- 1・2で止まったものは外部APIを呼ばず、3の回数にも数えない。
create or replace function public.preflight_write(p_user_id uuid, p_kind text, p_idempotency_key text default null)
returns void
language plpgsql
set search_path = public
as $$
declare
  limit_end timestamptz;
  bucket_name text := case when p_kind = 'image' then 'image' else 'text' end;
  max_requests integer := case when p_kind = 'image' then 10 else 30 end;
  current_window timestamptz := date_bin(interval '10 minutes', now(), timestamptz '2000-01-01');
  used integer;
  replaying boolean := false;
begin
  if p_kind not in ('post', 'comment', 'edit', 'profile', 'image') then
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
  end if;

  if p_kind in ('post', 'comment', 'edit') then
    perform public.assert_can_write(p_user_id);
  end if;

  -- 完了済みのIdempotency-Keyの再送は、最初の結果を返すだけで新しく作らない。上限の判定の対象にしない
  -- （最初の成功のあとで上限に達していても、再送が429にならないように）。
  if p_idempotency_key is not null and p_kind in ('post', 'comment') then
    select true into replaying from public.idempotency_keys
    where user_id = p_user_id and endpoint = p_kind || '.create' and key = p_idempotency_key and response is not null;
    replaying := coalesce(replaying, false);
  end if;

  if p_kind in ('post', 'comment') and not replaying then
    limit_end := public.new_user_limit_status(p_user_id, p_kind);
    if limit_end is not null then
      raise exception 'RATE_LIMITED' using errcode = 'P0001', detail = limit_end::text;
    end if;
  end if;

  insert into public.request_budget (user_id, bucket, window_start, request_count)
  values (p_user_id, bucket_name, current_window, 1)
  on conflict (user_id, bucket, window_start) do update
    set request_count = public.request_budget.request_count + 1
  returning request_count into used;

  if used > max_requests then
    raise exception 'REQUEST_LIMITED' using errcode = 'P0001', detail = (current_window + interval '10 minutes')::text;
  end if;
end;
$$;

-- 保持期限・古い行の掃除に、リクエスト数と作成の記録を追加する。
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

  return jsonb_build_object(
    'moderation_actions', n_actions,
    'reports', n_reports,
    'nickname_reservations', n_reservations,
    'idempotency_keys', n_keys,
    'request_budget', n_budget,
    'write_events', n_events
  );
end;
$$;

-- enforce_new_user_limit は、共通の判定（new_user_limit_status）を使う。
create or replace function public.enforce_new_user_limit(p_user_id uuid, p_kind text)
returns void
language plpgsql
set search_path = public
as $$
declare
  limit_end timestamptz;
begin
  -- 利用者単位のロックで、同時の作成でも上限を超えない。
  perform pg_advisory_xact_lock(hashtextextended('write_limit:' || p_user_id::text, 0));

  limit_end := public.new_user_limit_status(p_user_id, p_kind);
  if limit_end is not null then
    raise exception 'RATE_LIMITED' using errcode = 'P0001', detail = limit_end::text;
  end if;

  -- 上限の対象（運営者以外・窓の内側）だけを記録する。
  if public.new_user_limit_applies(p_user_id) then
    delete from public.write_events
    where user_id = p_user_id and created_at < now() - interval '30 days';
    insert into public.write_events (user_id, kind) values (p_user_id, p_kind);
  end if;
end;
$$;

-- 登録直後の制限の対象か（有効で、運営者でなく、登録から窓の内側）。
create or replace function public.new_user_limit_applies(p_user_id uuid)
returns boolean
language plpgsql
stable
set search_path = public
as $$
declare
  cfg jsonb := public.app_setting('new_user_limit');
  registered timestamptz;
begin
  if cfg is null or coalesce((cfg ->> 'enabled')::boolean, false) is not true then
    return false;
  end if;
  if exists (select 1 from public.admin_users where user_id = p_user_id) then
    return false;
  end if;
  select created_at into registered from public.profiles where id = p_user_id;
  if registered is null then
    return false;
  end if;
  return now() < registered + make_interval(hours => (cfg ->> 'window_hours')::integer);
end;
$$;

-- === (2) 退会の本人確認：操作中のセッションが作られた時刻 ===
-- ユーザー全体の last_sign_in_at ではなく、このセッション自身の作成時刻で判定する。
-- 別の端末で本人が再ログインしても、古い（盗まれた）セッションは「直近のログイン」にならない。
create or replace function public.session_started_at(p_session_id uuid, p_user_id uuid)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select created_at from auth.sessions where id = p_session_id and user_id = p_user_id;
$$;

-- === 権限：service_role専用 ===
do $$
declare
  fn text;
begin
  foreach fn in array array[
    'public.profiles_queue_avatar_deletion()',
    'public.claim_storage_deletions(integer)',
    'public.finish_storage_deletion(text, text, boolean, text)',
    'public.new_user_limit_status(uuid, text)',
    'public.new_user_limit_applies(uuid)',
    'public.preflight_write(uuid, text, text)',
    'public.purge_expired_records(timestamptz)',
    'public.enforce_new_user_limit(uuid, text)',
    'public.session_started_at(uuid, uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;
