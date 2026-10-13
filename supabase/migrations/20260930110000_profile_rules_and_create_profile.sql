-- Issue #12：ニックネームの初回変更・文字数の扱い、プロフィール登録を1トランザクションにまとめる関数。

-- === 初回の変更は制限しない（2026-09-30決定） ===
-- nickname_changed_at は「最後に変更した日時」。null は未変更（登録直後の誤字修正を許す）。
-- 2回目以降の変更は、前回の変更から30日空ける。
alter table public.profiles alter column nickname_changed_at drop not null;
alter table public.profiles alter column nickname_changed_at drop default;

comment on column public.profiles.nickname_changed_at is
  '最後にニックネームを変更した日時。null は未変更（初回の変更は制限しない）。';

-- === 文字数：絵文字等も見た目の1文字として数える（決定済み） ===
-- 2〜12文字・100文字の判定は、書記素（見た目の1文字）単位でEdge Functionが行う。
-- 絵文字1つが複数のコードポイントになる（家族の絵文字は7つ等）ため、DBはコードポイント数の
-- 緩い上限だけを持つ（12×8、100×7 を目安）。
alter table public.profiles drop constraint profiles_nickname_length;
alter table public.profiles
  add constraint profiles_nickname_length check (char_length(nickname) between 1 and 100);

alter table public.profiles drop constraint profiles_bio_length;
alter table public.profiles
  add constraint profiles_bio_length check (bio is null or char_length(bio) <= 700);

-- === ニックネーム変更の検証（初回変更の扱いを反映） ===
create or replace function public.profiles_before_write()
returns trigger
language plpgsql
as $$
declare
  reservation record;
  lock_key text;
begin
  new.normalized_nickname := public.normalize_nickname(new.nickname);
  new.updated_at := now();

  if tg_op = 'INSERT' or old.normalized_nickname is distinct from new.normalized_nickname then
    -- デッドロックを避けるため、常に名前の昇順でロックする。
    for lock_key in
      select k
      from (
        select distinct k
        from unnest(array[
          new.normalized_nickname,
          case when tg_op = 'UPDATE' then old.normalized_nickname end
        ]) as t(k)
        where k is not null
      ) names
      order by k
    loop
      perform pg_advisory_xact_lock(hashtextextended('nickname:' || lock_key, 0));
    end loop;
  end if;

  if tg_op = 'UPDATE' and old.normalized_nickname is distinct from new.normalized_nickname then
    if old.nickname_changed_at is not null
       and now() - old.nickname_changed_at < interval '30 days' then
      raise exception 'ニックネームは30日に1回まで変更できます' using errcode = 'P0001';
    end if;
    new.nickname_changed_at := now();
  end if;

  select * into reservation
  from public.nickname_reservations
  where normalized_nickname = new.normalized_nickname
    and reserved_until > now();

  if found and reservation.previous_owner_id is distinct from new.id then
    raise exception 'この名前は現在使用できません' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

-- === プロフィール登録（プロフィール・利用規約同意・通知設定を1トランザクションで作る） ===
-- Edge Functions（service_role）だけが呼ぶ。途中で失敗すればすべて取り消され、中途半端な登録は残らない。
-- 戻り値：'created'（新規作成）／'exists'（同じ名前で作成済み＝応答が届かなかった再送）／
--         'conflict'（同じ利用者が別の名前で作成済み）。
-- 名前が他の人に使われている・予約中の場合は、トリガーと一意制約の例外がそのまま伝わる。
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
as $$
declare
  inserted integer;
  result text := 'created';
begin
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

comment on function public.create_profile(uuid, text, text, text, text, text) is
  'プロフィール登録を1トランザクションで行う。service_role専用（Edge Functionsから呼ぶ）。';

revoke all on function public.create_profile(uuid, text, text, text, text, text) from public;
grant execute on function public.create_profile(uuid, text, text, text, text, text) to service_role;
