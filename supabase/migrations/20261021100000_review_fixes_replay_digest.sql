-- 外部レビューの指摘への対応（2026-10-21）。
--  1. 保存済みの再送は、外部API（送信前チェック）を呼ぶ前に、保存済みの結果を返せるようにする。
--  2. 共感のまとめ通知で、集計のあとにコミットされた共感が、永久に漏れないようにする。

-- === 1. 再送：保存済みの結果を先に取り出す ===
-- 完了済みのIdempotency-Keyの結果（作成した投稿・コメントのid、作成日時、相談先の案内）を返す。
-- 完了していない（処理中・未登録）なら null。外部APIが止まっていても、保存済みの結果は返せる。
create or replace function public.replay_idempotent_response(p_user_id uuid, p_kind text, p_key text)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  saved jsonb;
begin
  if p_key is null or p_kind not in ('post', 'comment') then
    return null;
  end if;
  select response into saved from public.idempotency_keys
  where user_id = p_user_id
    and endpoint = p_kind || '.create'
    and key = p_key
    and response is not null
    and created_at > now() - interval '24 hours';
  return saved;
end;
$$;

-- 作成の応答に含めた「相談先の案内」を、再送でも同じように返せるよう、保存済みの結果へ書き足す。
-- 本文は保存しない（フラグだけ）。書き足せなくても、再送で案内が出ないだけで、投稿には影響しない。
create or replace function public.remember_support_notice(p_user_id uuid, p_kind text, p_key text)
returns void
language plpgsql
set search_path = public
as $$
begin
  if p_key is null or p_kind not in ('post', 'comment') then
    return;
  end if;
  update public.idempotency_keys
  set response = response || jsonb_build_object('support_notice', true)
  where user_id = p_user_id
    and endpoint = p_kind || '.create'
    and key = p_key
    and response is not null;
end;
$$;

-- === 2. 共感のまとめ通知：共感ごとに「まとめ済み」を記録する ===
-- 以前は「前回の集計の時刻より後に作られた共感」を数えていたため、集計の前に始まり、集計のあとにコミットされた共感
-- （created_atは前回の時刻より前）が、次回以降も数えられなかった。共感ごとに記録し、まとめ通知に入ったものだけを済みにする。
alter table public.reactions add column digested_at timestamptz;
comment on column public.reactions.digested_at is
  'まとめ通知に含めた時刻。nullは、まだ通知に含めていない（集計のあとにコミットされた共感も、次回に数える）。';

-- 済みの記録で、共感の更新日時（updated_at）が動かないよう、種類を選び直したときだけ更新日時を動かす。
drop trigger reactions_set_updated_at on public.reactions;
create trigger reactions_set_updated_at
  before update of reaction_type_id on public.reactions
  for each row execute function public.set_updated_at();

-- この移行より前の共感は、これまでの方式で通知の対象かを決めてきたので、済みにする（二重に通知しない）。
update public.reactions set digested_at = now();

create index reactions_undigested_idx on public.reactions (created_at) where digested_at is null;

create or replace function public.generate_reaction_digests(p_now timestamptz default now())
returns integer
language plpgsql
set search_path = public
as $$
declare
  digest_day date := (p_now at time zone 'Asia/Tokyo')::date;
  created integer;
begin
  -- 1つの文の中で、数える共感（candidates）を決め、通知を作り、通知に入った共感だけを済みにする。
  -- この文の開始後にコミットされた共感は、candidatesに入らず、済みにもならないので、次回に数えられる。
  -- 数えないもの：自分の共感、ブロックした相手の共感、一時非表示の投稿への共感、設定で止めている人
  -- （どれも済みにしない。条件が変われば、7日以内なら次回に数える）。7日より古いものは通知しない。
  with candidates as (
    select rx.post_id, rx.user_id, p.author_id
    from public.reactions rx
    join public.posts p on p.id = rx.post_id
    where rx.digested_at is null
      and rx.created_at > p_now - interval '7 days'
      and rx.created_at <= p_now
      and p.hidden_at is null
      and rx.user_id <> p.author_id
      and not exists (
        select 1 from public.blocks b
        where b.blocker_id = p.author_id and b.blocked_id = rx.user_id
      )
      and public.notification_enabled(p.author_id, 'reaction_digest')
  ),
  counts as (
    select author_id as user_id, count(*)::integer as cnt from candidates group by author_id
  ),
  inserted as (
    insert into public.notifications (user_id, notification_type, reaction_count, digest_until, digest_date)
    select user_id, 'reaction_digest', cnt, p_now, digest_day from counts
    on conflict (user_id, digest_date) where notification_type = 'reaction_digest' do nothing
    returning user_id
  ),
  marked as (
    update public.reactions rx
    set digested_at = p_now
    from candidates c
    join inserted i on i.user_id = c.author_id
    where rx.post_id = c.post_id and rx.user_id = c.user_id
    returning 1
  )
  select count(*)::integer into created from inserted;

  return created;
end;
$$;

-- === 権限：service_role専用 ===
do $$
declare
  fn text;
begin
  foreach fn in array array[
    'public.replay_idempotent_response(uuid, text, text)',
    'public.remember_support_notice(uuid, text, text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end;
$$;
