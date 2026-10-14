-- Issue #15：共感（リアクション）の追加・選び直し・取消と、本人だけの保存一覧。
--
-- 共感の書き込みは、ブロック・利用停止・投稿の可視性・定型文の有効性の確認と保存を1トランザクションに
-- まとめたDB関数（service_role専用）に一本化する。authenticatedからの直接の書き込み権限は外す
-- （直接書き込みだと、ブロックされた相手の共感などをRLSだけで漏れなく拒否しにくいため）。
-- 取り消し・参照は本人のみ。件数は投稿者・運営者だけが関数で取得する（get_post_reaction_count）。

-- === 共感：直接の書き込みを外す ===
drop policy reactions_insert_own on public.reactions;
drop policy reactions_update_own on public.reactions;
drop policy reactions_delete_own on public.reactions;
revoke insert, update, delete on public.reactions from authenticated;

-- 共感の登録・変更（1投稿1人1つ。同時操作でも主キー(post_id, user_id)で1件に保つ）。
create or replace function public.set_reaction(
  p_user_id uuid, p_post_id uuid, p_reaction_type_id smallint
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  target record;
  saved record;
begin
  perform public.assert_can_write(p_user_id);

  select author_id, hidden_at into target from public.posts where id = p_post_id for share;
  if not found or target.hidden_at is not null then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;

  -- 自分の投稿には共感できない（件数は投稿者にだけ見えるため、水増しになる。暫定：未決事項）。
  if target.author_id = p_user_id then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from public.blocks where blocker_id = target.author_id and blocked_id = p_user_id
  ) then
    raise exception 'BLOCKED' using errcode = 'P0001';
  end if;

  if not exists (
    select 1 from public.reaction_types where id = p_reaction_type_id and is_active
  ) then
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
  end if;

  -- 受付が終了していても共感はできる（決定済み）。そのため、受付状態は確認しない。
  insert into public.reactions (post_id, user_id, reaction_type_id)
  values (p_post_id, p_user_id, p_reaction_type_id)
  on conflict (post_id, user_id) do update
    set reaction_type_id = excluded.reaction_type_id, updated_at = now()
  returning post_id, reaction_type_id, updated_at into saved;

  return jsonb_build_object(
    'post_id', saved.post_id,
    'reaction_type_id', saved.reaction_type_id,
    'updated_at', saved.updated_at
  );
end;
$$;

-- 共感の取消（本人のみ。常に可能。対象がなくても成功を返し、投稿の存在を知る手がかりにしない）。
create or replace function public.remove_reaction(p_user_id uuid, p_post_id uuid)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  removed integer;
begin
  delete from public.reactions where post_id = p_post_id and user_id = p_user_id;
  get diagnostics removed = row_count;
  return jsonb_build_object('deleted', removed > 0);
end;
$$;

revoke all on function public.set_reaction(uuid, uuid, smallint) from public, anon, authenticated;
revoke all on function public.remove_reaction(uuid, uuid) from public, anon, authenticated;
grant execute on function public.set_reaction(uuid, uuid, smallint) to service_role;
grant execute on function public.remove_reaction(uuid, uuid) to service_role;

-- === 保存：本人だけ。見えない投稿は保存できない ===
-- 以前のポリシーは、非表示・削除済みなどの投稿IDも保存できてしまい、外部キー違反の有無で投稿の存在が
-- 分かった。可視な投稿（ブロック・自分だけの非表示を除く）に限り、失敗の理由を区別しない。
drop policy saved_posts_all_own on public.saved_posts;
revoke update on public.saved_posts from authenticated;

create policy saved_posts_select_own
  on public.saved_posts
  for select
  to authenticated
  using (user_id = auth.uid());

create policy saved_posts_insert_own
  on public.saved_posts
  for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.member_posts m where m.id = saved_posts.post_id)
  );

create policy saved_posts_delete_own
  on public.saved_posts
  for delete
  to authenticated
  using (user_id = auth.uid());

-- 保存一覧（本人のみ）。見えなくなった投稿（削除・一時非表示・ブロック・自分だけの非表示）は出ない。
-- 保存した事実・保存数は、他の人に公開しない（saved_postsは本人のRLS、postsの列にも保存数はない）。
create view public.saved_post_list
  with (security_invoker = true) as
select s.created_at as saved_at, m.*
from public.saved_posts s
join public.member_posts m on m.id = s.post_id;

comment on view public.saved_post_list is
  '本人の保存一覧。保存日時の新しい順は、クライアントがsaved_atで指定する。';

grant select on public.saved_post_list to authenticated;
