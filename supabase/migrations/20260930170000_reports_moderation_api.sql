-- Issue #17：通報・自動一時非表示・運営の対処。
--
-- 書き込みはEdge Functions（service_role）→ service_role専用のDB関数。運営者の判定は、Edge Functionの
-- 二段階認証（aal2）の確認に加えて、DBでも行う（is_admin()がaal2を要求する。直接REST/RLSでも守られる）。
-- 通報者の情報は、通報された側に一切出さない。

-- === 運営者の判定：二段階認証済み（aal2）のセッションに限る ===
-- JWTのaalクレームはSupabase Authが付与する。admin_usersに登録されていても、二段階認証を
-- 済ませていないセッション（aal1）は運営者として扱わない。
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.admin_users where user_id = auth.uid())
     and coalesce(auth.jwt() ->> 'aal', '') = 'aal2';
$$;

comment on function public.is_admin() is
  '呼び出し中の利用者が運営者（admin_users登録済み、かつ二段階認証済みのaal2セッション）かどうかを判定する。';

-- === 通報 ===
-- 理由は6種（Notion F-05）。detailは任意（「その他」は一言添えられる）。
alter table public.reports
  add constraint reports_reason_check
  check (reason in ('harassment', 'personal_info', 'spam', 'copyright', 'danger', 'other'));
alter table public.reports
  add constraint reports_detail_length check (detail is null or char_length(detail) <= 700);

-- === 運営の対処 ===
-- 警告・利用停止・相談先案内は、利用者単位の操作（target_type = 'user'）。投稿・コメントへの
-- 再表示・削除は、これまでどおり。
alter table public.moderation_actions drop constraint moderation_actions_target_type_check;
alter table public.moderation_actions
  add constraint moderation_actions_target_type_check
  check (target_type in ('post', 'comment', 'user'));

alter table public.moderation_actions drop constraint moderation_actions_action_check;
alter table public.moderation_actions
  add constraint moderation_actions_action_check
  check (action in ('unhide', 'delete', 'warn', 'suspend', 'guide'));

alter table public.moderation_actions
  add constraint moderation_actions_action_target
  check (
    (action in ('unhide', 'delete') and target_type in ('post', 'comment'))
    or (action in ('warn', 'suspend', 'guide') and target_type = 'user')
  );

-- 本人への通知から、対処の内容（理由）を引けるようにする。
-- 理由は、本人が対象の記録だけをmoderation_actionsのRLSで読める（通報者の情報は含まれない）。
alter table public.notifications
  add column moderation_action_id uuid references public.moderation_actions (id) on delete cascade;

-- 対象の所有者を、挿入時点で記録する（削除後は引けなくなるため）。
create or replace function public.moderation_actions_before_insert()
returns trigger
language plpgsql
as $$
begin
  if new.target_type = 'post' then
    select author_id into new.target_owner_id from public.posts where id = new.target_id;
  elsif new.target_type = 'comment' then
    select author_id into new.target_owner_id from public.comments where id = new.target_id;
  elsif new.target_type = 'user' then
    new.target_owner_id := new.target_id;
  end if;
  return new;
end;
$$;

-- unhide：未対応通報をまとめて解消し、一時非表示を解除する（再表示後は再集計しない）。
-- delete：投稿は削除、コメントはソフト削除。未対応通報は対処済みにする。本人へ理由を通知する。
-- warn・suspend・guide：本人へ通知する（利用停止の制限は、DB関数がaccount_restrictionsに作る）。
create or replace function public.moderation_actions_apply()
returns trigger
language plpgsql
as $$
begin
  if new.action = 'unhide' then
    update public.reports
      set resolved_at = now(), resolved_by = new.admin_id
      where target_type = new.target_type and target_id = new.target_id and resolved_at is null;

    if new.target_type = 'post' then
      update public.posts set hidden_at = null where id = new.target_id;
    elsif new.target_type = 'comment' then
      update public.comments set hidden_at = null where id = new.target_id;
    end if;
  elsif new.action = 'delete' then
    update public.reports
      set resolved_at = now(), resolved_by = new.admin_id
      where target_type = new.target_type and target_id = new.target_id and resolved_at is null;

    if new.target_type = 'post' then
      delete from public.posts where id = new.target_id;
    elsif new.target_type = 'comment' then
      update public.comments set deleted_at = now() where id = new.target_id and deleted_at is null;
    end if;
  end if;

  -- 本人へ通知する（再表示は通知しない。確認中の表示が消えるだけでよい）。
  if new.action <> 'unhide' and new.target_owner_id is not null then
    insert into public.notifications (user_id, notification_type, moderation_action_id)
    values (new.target_owner_id, 'moderation', new.id);
  end if;

  return new;
end;
$$;

-- 通報の作成。同じ人・同じ対象の未対応通報は1件にまとめる（既存の行を返す）。
-- 通報できるのは、自分に見える投稿・コメントで、自分のものではないもの。
-- 存在しない・一時非表示・削除済みは、どれも NOT_FOUND（存在を知る手がかりにしない）。
create or replace function public.create_report(
  p_reporter_id uuid,
  p_target_type text,
  p_target_id uuid,
  p_reason text,
  p_detail text
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  owner uuid;
  hidden timestamptz;
  deleted timestamptz;
  post_hidden timestamptz;
  inserted integer;
  report_id uuid;
begin
  perform public.assert_can_write(p_reporter_id);

  if p_reason not in ('harassment', 'personal_info', 'spam', 'copyright', 'danger', 'other')
     or p_target_type not in ('post', 'comment') then
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
  end if;

  if p_target_type = 'post' then
    select author_id, hidden_at into owner, hidden from public.posts where id = p_target_id;
    if not found or hidden is not null then
      raise exception 'NOT_FOUND' using errcode = 'P0001';
    end if;
  else
    select c.author_id, c.hidden_at, c.deleted_at, p.hidden_at
      into owner, hidden, deleted, post_hidden
    from public.comments c join public.posts p on p.id = c.post_id
    where c.id = p_target_id;
    if not found or hidden is not null or deleted is not null or post_hidden is not null then
      raise exception 'NOT_FOUND' using errcode = 'P0001';
    end if;
  end if;

  if owner = p_reporter_id then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;

  insert into public.reports (reporter_id, target_type, target_id, reason, detail)
  values (p_reporter_id, p_target_type, p_target_id, p_reason, nullif(btrim(p_detail), ''))
  on conflict (reporter_id, target_type, target_id) where resolved_at is null do nothing
  returning id into report_id;

  get diagnostics inserted = row_count;
  if inserted = 0 then
    select id into report_id from public.reports
    where reporter_id = p_reporter_id and target_type = p_target_type
      and target_id = p_target_id and resolved_at is null;
  end if;

  return jsonb_build_object('id', report_id, 'duplicate', inserted = 0);
end;
$$;

-- 運営の対処。運営者の登録をDBでも確認する（Edge Functionの確認に頼りきらない）。
-- 二段階認証（aal2）の確認は、JWTを持つEdge Functionで行う。
-- security definer：利用停止のときに auth.sessions（再ログインを求めるためのセッション削除）を
-- 操作する必要があり、service_role にauthスキーマの権限を広げずに済ませるため。関数の中で
-- auth.uid() には依存せず、渡された運営者のIDをadmin_usersで確認している。実行できるのは
-- service_role だけ（下で他のロールのEXECUTEを外している）。
create or replace function public.moderation_apply(
  p_admin_id uuid,
  p_target_type text,
  p_target_id uuid,
  p_action text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reason text := nullif(btrim(p_reason), '');
  action_id uuid;
  past integer;
  new_stage smallint;
  restriction_id uuid;
begin
  if not exists (select 1 from public.admin_users where user_id = p_admin_id) then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;

  if p_target_type not in ('post', 'comment', 'user')
     or p_action not in ('unhide', 'delete', 'warn', 'suspend', 'guide')
     or not (
       (p_action in ('unhide', 'delete') and p_target_type in ('post', 'comment'))
       or (p_action in ('warn', 'suspend', 'guide') and p_target_type = 'user')
     ) then
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
  end if;
  -- 本人へ通知する理由は、削除・警告・利用停止では必須。
  if p_action in ('delete', 'warn', 'suspend') and reason is null then
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
  end if;
  if reason is not null and char_length(reason) > 700 then
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
  end if;

  -- 対象の存在確認。
  if p_target_type = 'post' and not exists (select 1 from public.posts where id = p_target_id) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if p_target_type = 'comment' and not exists (
    select 1 from public.comments where id = p_target_id and deleted_at is null
  ) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if p_target_type = 'user' then
    if not exists (select 1 from public.profiles where id = p_target_id) then
      raise exception 'NOT_FOUND' using errcode = 'P0001';
    end if;
    -- 運営者自身には、警告・利用停止をかけない（運営の締め出しを防ぐ）。
    if exists (select 1 from public.admin_users where user_id = p_target_id) then
      raise exception 'FORBIDDEN' using errcode = 'P0001';
    end if;
  end if;

  -- 利用停止：同じ利用者への同時の操作を直列化し、すでに停止中なら二重に段階を進めない。
  if p_action = 'suspend' then
    perform pg_advisory_xact_lock(hashtextextended('suspend:' || p_target_id::text, 0));
    if public.is_restricted(p_target_id) then
      raise exception 'CONFLICT' using errcode = 'P0001';
    end if;

    -- 段階は、早期解除されていない過去の制限の件数で決める（初回7日→再発30日→再発以降は無期限）。
    select count(*) into past from public.account_restrictions
      where user_id = p_target_id and lifted_at is null;
    new_stage := least(past + 1, 3);

    insert into public.account_restrictions (user_id, stage, starts_at, ends_at, reason, created_by)
    values (
      p_target_id, new_stage, now(),
      case new_stage when 1 then now() + interval '7 days' when 2 then now() + interval '30 days' end,
      reason, p_admin_id
    )
    returning id into restriction_id;

    -- 利用停止のときは、再ログインさせる（Notion：ログイン状態の保持の例外）。
    delete from auth.sessions where user_id = p_target_id;
  end if;

  insert into public.moderation_actions (admin_id, target_type, target_id, action, reason)
  values (p_admin_id, p_target_type, p_target_id, p_action, reason)
  returning id into action_id;

  return jsonb_build_object(
    'id', action_id,
    'action', p_action,
    'restriction_stage', new_stage
  );
end;
$$;

-- === 本人へ「確認中」を返す ===
-- 一時非表示の投稿は、本人だけに「確認中」として見える（ほかの人には非表示のまま）。
create view public.my_posts
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
  p.edited_at,
  (p.hidden_at is not null) as under_review,
  public.post_comment_count(p.id) as comment_count
from public.posts p
where p.author_id = auth.uid();

comment on view public.my_posts is
  '本人の投稿（確認中のものを含む）。under_reviewがtrueなら、通報による一時非表示で運営が確認中。';

-- 一時非表示のコメントも、投稿者本人にだけ見える（「確認中」）。
create policy comments_select_own_hidden
  on public.comments
  for select
  to authenticated
  using (author_id = auth.uid() and hidden_at is not null and deleted_at is null);

create or replace view public.member_comments
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
  pr.avatar_path as author_avatar_path,
  (c.hidden_at is not null) as under_review
from public.comments c
left join public.public_profiles pr on pr.id = c.author_id
where not exists (
    select 1 from public.blocks b
    where b.blocker_id = auth.uid() and b.blocked_id = c.author_id
  )
  and not exists (
    select 1 from public.hidden_items h
    where h.user_id = auth.uid() and h.target_type = 'comment' and h.target_id = c.id
  );

-- === 運営の通報一覧（Notion F-11：理由・件数・日時つき、一時非表示中を優先） ===
-- 対象ごとに未対応の通報をまとめる。運営者（二段階認証済み）だけが中身を見られる。
create view public.admin_report_queue
  with (security_invoker = true) as
select
  r.target_type,
  r.target_id,
  count(distinct r.reporter_id) as report_count,
  array_agg(distinct r.reason order by r.reason) as reasons,
  min(r.created_at) as first_reported_at,
  max(r.created_at) as last_reported_at,
  (coalesce(p.hidden_at, c.hidden_at) is not null) as is_hidden,
  coalesce(p.author_id, c.author_id) as target_owner_id,
  coalesce(p.body, c.body) as body
from public.reports r
left join public.posts p on r.target_type = 'post' and p.id = r.target_id
left join public.comments c on r.target_type = 'comment' and c.id = r.target_id
where r.resolved_at is null
  and public.is_admin()
  and (p.id is not null or c.id is not null)
group by r.target_type, r.target_id, p.hidden_at, c.hidden_at, p.author_id, c.author_id, p.body, c.body;

comment on view public.admin_report_queue is
  '運営向けの通報一覧（対象ごと）。is_admin()（二段階認証済みの運営者）でなければ空。並びはクライアントが is_hidden・last_reported_at で指定する。';

-- === 権限 ===
grant select on public.my_posts, public.admin_report_queue to authenticated;

revoke all on function public.create_report(uuid, text, uuid, text, text) from public, anon, authenticated;
revoke all on function public.moderation_apply(uuid, text, uuid, text, text) from public, anon, authenticated;
grant execute on function public.create_report(uuid, text, uuid, text, text) to service_role;
grant execute on function public.moderation_apply(uuid, text, uuid, text, text) to service_role;
