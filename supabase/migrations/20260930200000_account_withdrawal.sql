-- Issue #20：退会・関連データ削除・保持期限の削除。
--
-- 決定（2026-10-15）：取消期間は設けない（即時削除）／本人確認は直近5分以内のログイン／
-- 運営者は、運営者の登録を外してから退会する。
--
-- 退会は withdraw_account の1トランザクションで行う。途中で失敗したら全体が戻るので、
-- 何度でも安全に再実行できる（AuthのユーザーとDBの削除がずれる中間状態を作らない）。

-- === 保持する記録が、運営者・通報者のアカウント削除を妨げないようにする ===
-- 通報・対処の記録は退会後も1年残す（決定済み）。記録に残る「誰が」は、アカウントが消えたら空になる
-- （退会済みの運営者・通報者）。アカウントの削除そのものは妨げない。
alter table public.reports alter column reporter_id drop not null;
alter table public.reports drop constraint reports_reporter_id_fkey;
alter table public.reports
  add constraint reports_reporter_id_fkey foreign key (reporter_id) references auth.users (id) on delete set null;
alter table public.reports drop constraint reports_resolved_by_fkey;
alter table public.reports
  add constraint reports_resolved_by_fkey foreign key (resolved_by) references auth.users (id) on delete set null;

alter table public.moderation_actions alter column admin_id drop not null;
alter table public.moderation_actions drop constraint moderation_actions_admin_id_fkey;
alter table public.moderation_actions
  add constraint moderation_actions_admin_id_fkey foreign key (admin_id) references auth.users (id) on delete set null;

alter table public.account_restrictions alter column created_by drop not null;
alter table public.account_restrictions drop constraint account_restrictions_created_by_fkey;
alter table public.account_restrictions
  add constraint account_restrictions_created_by_fkey foreign key (created_by) references auth.users (id) on delete set null;

alter table public.app_settings drop constraint app_settings_updated_by_fkey;
alter table public.app_settings
  add constraint app_settings_updated_by_fkey foreign key (updated_by) references auth.users (id) on delete set null;

alter table public.app_settings_history alter column changed_by drop not null;
alter table public.app_settings_history drop constraint app_settings_history_changed_by_fkey;
alter table public.app_settings_history
  add constraint app_settings_history_changed_by_fkey foreign key (changed_by) references auth.users (id) on delete set null;

comment on column public.moderation_actions.admin_id is
  '対処した運営者。運営者のアカウントが削除されたら空になる（記録は保持期間まで残す）。';
comment on column public.reports.reporter_id is
  '通報者。通報者が退会したら空になる（通報の記録は保持期間まで残す）。';

-- === 退会 ===
-- 削除するもの：プロフィール・投稿・コメント・返信・共感・保存・非表示・ブロック・ミュート・通知・通知設定・
--   端末・利用規約の同意・再送防止キー・停止の履歴・Authのアカウント（セッション・連携を含む）。
--   外部キーのカスケードで消えるものに加えて、外部キーのない論理参照（他人の非表示 hidden_items）と、
--   自分が起こした通知（actor_id）を明示的に消す。
-- 残すもの：通報・対処の記録（1年）、ニックネームの30日の予約。
-- 運営者として登録されている間は退会できない（先に登録を外す）。
create or replace function public.withdraw_account(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  nick_normalized text;
begin
  if not exists (select 1 from auth.users where id = p_user_id) then
    return jsonb_build_object('status', 'already_deleted');
  end if;

  -- 同じ人の退会を直列化する（二重のリクエストが重ならない）。
  perform pg_advisory_xact_lock(hashtextextended('withdraw:' || p_user_id::text, 0));

  if exists (select 1 from public.admin_users where user_id = p_user_id) then
    raise exception 'OPERATOR_REGISTERED' using errcode = 'P0001';
  end if;

  -- ニックネームを30日間予約する（他人が使えない）。
  select normalized_nickname into nick_normalized from public.profiles where id = p_user_id;
  if nick_normalized is not null then
    insert into public.nickname_reservations (normalized_nickname, reserved_until, previous_owner_id, reason)
    values (nick_normalized, now() + interval '30 days', p_user_id, 'withdrawn')
    on conflict (normalized_nickname) do update
      set reserved_until = greatest(public.nickname_reservations.reserved_until, excluded.reserved_until),
          previous_owner_id = excluded.previous_owner_id,
          reason = excluded.reason;
  end if;

  -- 消える投稿・コメントへの未対応の通報は、対応済みにする（記録は保持期間まで残す）。
  update public.reports
  set resolved_at = now()
  where resolved_at is null
    and (
      (target_type = 'post' and target_id in (select id from public.posts where author_id = p_user_id))
      or (target_type = 'comment' and target_id in (
        select id from public.comments
        where author_id = p_user_id
           or post_id in (select id from public.posts where author_id = p_user_id)
      ))
    );

  -- 他の人の「非表示」のうち、消える投稿・コメントを指すもの（外部キーがないので明示的に消す）。
  delete from public.hidden_items
  where (target_type = 'post' and target_id in (select id from public.posts where author_id = p_user_id))
     or (target_type = 'comment' and target_id in (
       select id from public.comments
       where author_id = p_user_id
          or post_id in (select id from public.posts where author_id = p_user_id)
     ));

  -- 自分が起こした通知（他の人宛て）。コメントごと消える。
  delete from public.notifications where actor_id = p_user_id;

  -- Authのアカウントを削除する。残りは外部キーのカスケードで一緒に消える。
  delete from auth.users where id = p_user_id;

  return jsonb_build_object('status', 'deleted');
end;
$$;

-- === 保持期限を過ぎた記録の削除 ===
-- 通報・対処の記録は1年（決定済み）。期限が切れたニックネームの予約も消す。
-- 再送防止キーは24時間を過ぎたものを、次回の呼び出しで消している（個別に削除）が、ここでも掃除する。
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
begin
  delete from public.moderation_actions where created_at < p_now - interval '1 year';
  get diagnostics n_actions = row_count;

  delete from public.reports where created_at < p_now - interval '1 year';
  get diagnostics n_reports = row_count;

  delete from public.nickname_reservations where reserved_until < p_now;
  get diagnostics n_reservations = row_count;

  delete from public.idempotency_keys where created_at < p_now - interval '24 hours';
  get diagnostics n_keys = row_count;

  return jsonb_build_object(
    'moderation_actions', n_actions,
    'reports', n_reports,
    'nickname_reservations', n_reservations,
    'idempotency_keys', n_keys
  );
end;
$$;

-- 毎日 18:00 UTC（日本時間の午前3時）に実行する。
select cron.schedule('purge-expired-daily', '0 18 * * *', $$select public.purge_expired_records()$$);

-- === 権限：service_role専用 ===
revoke all on function public.withdraw_account(uuid) from public, anon, authenticated;
revoke all on function public.purge_expired_records(timestamptz) from public, anon, authenticated;
grant execute on function public.withdraw_account(uuid) to service_role;
grant execute on function public.purge_expired_records(timestamptz) to service_role;
