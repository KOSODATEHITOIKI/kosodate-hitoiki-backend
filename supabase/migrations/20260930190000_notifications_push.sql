-- Issue #19：アプリ内通知・プッシュ通知と設定。
--
-- 決定済み（2026-10-15）：配信はFCM、共感のまとめ通知は1日1回（朝7時・日本時間）、
-- プッシュには本文を含めない（定型文だけ）、返信の通知はコメントとは別に設定で切れる。

-- === 通知の列：共感のまとめ通知 ===
alter table public.notifications
  add column reaction_count integer check (reaction_count is null or reaction_count >= 1),
  add column digest_until timestamptz,
  add column digest_date date;

alter table public.notifications
  add constraint notifications_digest_columns check (
    (notification_type = 'reaction_digest')
    = (reaction_count is not null and digest_until is not null and digest_date is not null)
  );

comment on column public.notifications.reaction_count is
  '共感のまとめ通知（reaction_digest）だけ：まとめた共感の数。投稿者本人にだけ届く。';
comment on column public.notifications.digest_until is
  '共感のまとめ通知だけ：この時刻までの共感を集計した。次回はここから数える。';

-- 同じ日に、同じ人へのまとめ通知は1通だけ（同じ処理を2回動かしても重複しない）。
create unique index notifications_one_digest_per_day
  on public.notifications (user_id, digest_date)
  where notification_type = 'reaction_digest';

-- 1つのコメント・返信は、1人に1通だけ通知する。
create unique index notifications_one_per_comment
  on public.notifications (user_id, comment_id, notification_type)
  where comment_id is not null and notification_type in ('comment', 'reply');

-- === 通知の設定を、通知の作成に反映する ===
-- 設定の行がなければ、すべて有効として扱う。
create or replace function public.notification_enabled(p_user_id uuid, p_type text)
returns boolean
language sql
stable
set search_path = public
as $$
  select case p_type
    when 'comment' then coalesce((select comments_enabled from public.notification_settings where user_id = p_user_id), true)
    when 'reply' then coalesce((select replies_enabled from public.notification_settings where user_id = p_user_id), true)
    when 'reaction_digest' then coalesce((select reactions_enabled from public.notification_settings where user_id = p_user_id), true)
    else true -- 運営からのお知らせは止められない
  end;
$$;

create or replace function public.comments_after_insert_notify()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  post_author uuid;
  parent_author uuid;
begin
  if new.parent_comment_id is null then
    select author_id into post_author from public.posts where id = new.post_id;
    if post_author is not null and post_author <> new.author_id
       and public.notification_enabled(post_author, 'comment') then
      insert into public.notifications (user_id, notification_type, actor_id, post_id, comment_id)
      values (post_author, 'comment', new.author_id, new.post_id, new.id)
      on conflict do nothing;
    end if;
  else
    select author_id into parent_author from public.comments where id = new.parent_comment_id;
    if parent_author is not null and parent_author <> new.author_id
       and public.notification_enabled(parent_author, 'reply') then
      insert into public.notifications (user_id, notification_type, actor_id, post_id, comment_id)
      values (parent_author, 'reply', new.author_id, new.post_id, new.id)
      on conflict do nothing;
    end if;
  end if;
  return null;
end;
$$;

-- === 共感のまとめ通知（1日1回） ===
-- 前回のまとめ以降の共感を、投稿者ごとに数えて1通にする。
-- 数えないもの：自分の共感、ブロックした相手の共感、一時非表示の投稿への共感、設定で止めている人。
-- 前回がなければ、7日前から数える。止めている間の共感は、再開しても7日より古いものは通知しない。
-- 集計の時刻より後に確定した共感は、次回に回る（取りこぼしは1日分の遅れにとどめる）。
create or replace function public.generate_reaction_digests(p_now timestamptz default now())
returns integer
language plpgsql
set search_path = public
as $$
declare
  digest_day date := (p_now at time zone 'Asia/Tokyo')::date;
  created integer;
begin
  with last_digest as (
    select user_id, max(digest_until) as until
    from public.notifications
    where notification_type = 'reaction_digest'
    group by user_id
  ),
  counts as (
    select p.author_id as user_id, count(*)::integer as cnt
    from public.reactions rx
    join public.posts p on p.id = rx.post_id
    left join last_digest l on l.user_id = p.author_id
    where p.hidden_at is null
      and rx.user_id <> p.author_id
      and rx.created_at > greatest(coalesce(l.until, '-infinity'::timestamptz), p_now - interval '7 days')
      and rx.created_at <= p_now
      and not exists (
        select 1 from public.blocks b
        where b.blocker_id = p.author_id and b.blocked_id = rx.user_id
      )
      and public.notification_enabled(p.author_id, 'reaction_digest')
    group by p.author_id
  )
  insert into public.notifications (user_id, notification_type, reaction_count, digest_until, digest_date)
  select user_id, 'reaction_digest', cnt, p_now, digest_day from counts
  on conflict (user_id, digest_date) where notification_type = 'reaction_digest' do nothing;

  get diagnostics created = row_count;
  return created;
end;
$$;

-- 毎日 22:00 UTC（日本時間の朝7時）に実行する。
create extension if not exists pg_cron;
select cron.schedule('reaction-digest-daily', '0 22 * * *', $$select public.generate_reaction_digests()$$);

-- === 端末の登録 ===
-- 端末トークンは1つの端末を表す。同じ端末で別の人がログインしたら、持ち主を移す。
-- （直接のINSERT/UPDATEだと、前の持ち主の行が残り、前の人宛ての通知が次の人の端末へ届いてしまう。）
-- 持ち主が変わるときは、行を作り直して、前の人宛ての未送信の配信を消す。
create or replace function public.register_push_device(p_platform text, p_token text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  device_id uuid;
begin
  if uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'P0001';
  end if;
  if p_platform not in ('ios', 'android') or p_token is null or char_length(p_token) not between 8 and 4096 then
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.profiles where id = uid) then
    raise exception 'PROFILE_REQUIRED' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('push_device:' || p_token, 0));

  -- 別の人の端末として登録されていれば、その行（と未送信の配信）を消す。
  delete from public.push_devices where device_token = p_token and user_id <> uid;

  insert into public.push_devices (user_id, platform, device_token)
  values (uid, p_platform, p_token)
  on conflict (device_token) do update set platform = excluded.platform, last_seen_at = now()
  returning id into device_id;

  -- 1人あたり10台まで。古い順に外す。
  delete from public.push_devices
  where user_id = uid
    and id not in (
      select id from public.push_devices where user_id = uid order by last_seen_at desc limit 10
    );

  return device_id;
end;
$$;

-- 直接の登録・更新はさせない（登録は上の関数だけ）。参照と削除（ログアウト時の解除）は本人だけ。
drop policy push_devices_all_own on public.push_devices;
create policy push_devices_select_own
  on public.push_devices for select to authenticated using (user_id = auth.uid());
create policy push_devices_delete_own
  on public.push_devices for delete to authenticated using (user_id = auth.uid());
revoke insert, update on public.push_devices from authenticated;

-- === プッシュの配信キュー（端末ごと） ===
create table public.push_deliveries (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.notifications (id) on delete cascade,
  device_id uuid not null references public.push_devices (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'skipped')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  locked_until timestamptz,
  last_error text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  unique (notification_id, device_id)
);

comment on table public.push_deliveries is
  'プッシュの配信キュー（通知×端末）。再送で重複しないよう、同じ通知・同じ端末は1行。service_role専用。last_errorはエラーコードだけ（本文・トークンは入れない）。';

create index push_deliveries_pending_idx
  on public.push_deliveries (next_attempt_at) where status = 'pending';

alter table public.push_deliveries enable row level security;
-- ポリシーなし（anon・authenticatedは参照も書き込みもできない）。
grant all on public.push_deliveries to service_role;

-- プッシュを送ってよいか：端末設定（push_enabled）と、種類ごとの設定の両方が有効なとき。
create or replace function public.push_allowed(p_user_id uuid, p_type text)
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce((select push_enabled from public.notification_settings where user_id = p_user_id), true)
    and public.notification_enabled(p_user_id, p_type);
$$;

-- 通知ができたら、その人の端末ごとに配信を積む。
create or replace function public.notifications_after_insert_enqueue_push()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if public.push_allowed(new.user_id, new.notification_type) then
    insert into public.push_deliveries (notification_id, device_id)
    select new.id, d.id from public.push_devices d where d.user_id = new.user_id
    on conflict do nothing;
  end if;
  return null;
end;
$$;

create trigger notifications_after_insert_enqueue_push
  after insert on public.notifications
  for each row execute function public.notifications_after_insert_enqueue_push();

-- 送る分を取り出す。取り出した行は5分間ロックし、同時に動く別の配信と重ならない。
-- 取り出す前に、送るべきでなくなったもの（設定を止めた・既読にした・ブロックした・
-- 端末の持ち主が変わった）は「skipped」にして送らない。
create or replace function public.claim_push_deliveries(p_limit integer default 50)
returns table (
  delivery_id uuid,
  notification_id uuid,
  notification_type text,
  platform text,
  device_token text
)
language plpgsql
set search_path = public
as $$
begin
  update public.push_deliveries d
  set status = 'skipped', locked_until = null
  where d.status = 'pending'
    and d.next_attempt_at <= now()
    and not exists (
      select 1
      from public.notifications n
      join public.push_devices dv on dv.id = d.device_id and dv.user_id = n.user_id
      where n.id = d.notification_id
        and not n.is_read
        and public.push_allowed(n.user_id, n.notification_type)
        and (n.actor_id is null or not exists (
          select 1 from public.blocks b where b.blocker_id = n.user_id and b.blocked_id = n.actor_id
        ))
    );

  return query
  with picked as (
    select d.id
    from public.push_deliveries d
    where d.status = 'pending'
      and d.next_attempt_at <= now()
      and (d.locked_until is null or d.locked_until < now())
    order by d.next_attempt_at
    limit greatest(1, least(p_limit, 200))
    for update skip locked
  ),
  locked as (
    update public.push_deliveries d
    set locked_until = now() + interval '5 minutes'
    from picked
    where d.id = picked.id
    returning d.id, d.notification_id, d.device_id
  )
  select l.id, l.notification_id, n.notification_type, dv.platform, dv.device_token
  from locked l
  join public.notifications n on n.id = l.notification_id
  join public.push_devices dv on dv.id = l.device_id;
end;
$$;

-- 配信の結果を記録する。
--   sent          送れた
--   retry         一時的な失敗。1・5・25・125分後に再試行し、5回目で打ち切る（failed）
--   invalid_token 端末が無効。端末ごと削除する（配信も一緒に消える）
create or replace function public.finish_push_delivery(p_delivery_id uuid, p_outcome text, p_error text default null)
returns void
language plpgsql
set search_path = public
as $$
declare
  safe_error text := case when p_error ~ '^[A-Za-z0-9_]{1,40}$' then p_error else 'UNKNOWN' end;
  current_attempts integer;
begin
  if p_outcome = 'sent' then
    update public.push_deliveries
    set status = 'sent', sent_at = now(), locked_until = null, last_error = null
    where id = p_delivery_id;
  elsif p_outcome = 'retry' then
    select attempts into current_attempts from public.push_deliveries where id = p_delivery_id;
    if current_attempts is null then
      return;
    end if;
    if current_attempts + 1 >= 5 then
      update public.push_deliveries
      set status = 'failed', attempts = current_attempts + 1, locked_until = null, last_error = safe_error
      where id = p_delivery_id;
    else
      update public.push_deliveries
      set attempts = current_attempts + 1,
          next_attempt_at = now() + (interval '1 minute' * power(5, current_attempts)),
          locked_until = null,
          last_error = safe_error
      where id = p_delivery_id;
    end if;
  elsif p_outcome = 'invalid_token' then
    delete from public.push_devices
    where id = (select device_id from public.push_deliveries where id = p_delivery_id);
  else
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
  end if;
end;
$$;

-- === 権限：内部の関数は service_role 専用。端末の登録だけ、ログイン済みの利用者に開く ===
do $$
declare
  fn text;
begin
  foreach fn in array array[
    'public.notification_enabled(uuid, text)',
    'public.comments_after_insert_notify()',
    'public.generate_reaction_digests(timestamptz)',
    'public.push_allowed(uuid, text)',
    'public.notifications_after_insert_enqueue_push()',
    'public.claim_push_deliveries(integer)',
    'public.finish_push_delivery(uuid, text, text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;

revoke all on function public.register_push_device(text, text) from public, anon;
grant execute on function public.register_push_device(text, text) to authenticated, service_role;
