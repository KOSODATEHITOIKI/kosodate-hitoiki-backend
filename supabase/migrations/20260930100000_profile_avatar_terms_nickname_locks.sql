-- Issue #12：アカウント画像（イラスト選択とアップロードの両対応）、利用規約同意の記録、
-- ニックネームの同時登録・変更に対する保護。

-- === アカウント画像 ===
-- 「用意したイラストを選ぶ（icon_key）」か「自分の画像をアップロードする（avatar_path）」のどちらか一方。
-- avatar_pathはStorageの`avatars`バケット内のパス（<user_id>/<ファイル名>）。
alter table public.profiles add column avatar_path text;

alter table public.profiles
  add constraint profiles_icon_or_avatar check (icon_key is null or avatar_path is null);

comment on column public.profiles.avatar_path is
  'アップロードしたアカウント画像のStorageパス（avatarsバケット）。icon_keyとは排他。書き込みはEdge Functionsのみ。';

-- 公開プロフィールにも画像の場所を出す（ニックネームと同じ公開範囲）。列は末尾に追加する。
create or replace view public.public_profiles as
select id, nickname, icon_key, avatar_path
from public.profiles;

-- Storageの`avatars`バケット：閲覧は公開URL、書き込みはEdge Functions（service_role）のみ。
-- storage.objectsにはクライアント向けのINSERT/UPDATE/DELETEポリシーを作らない（確認を迂回させない）。
-- Supabase以外（AWSではS3）にはStorageがないため、storageスキーマがあるときだけ作る。
do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('avatars', 'avatars', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
    on conflict (id) do nothing;
  end if;
end
$$;

-- === 利用規約同意の記録 ===
-- 規約の版（terms_version）は運営が付ける文字列。規約本文・法務確認は別途（docs/未決事項.md）。
create table public.terms_acceptances (
  user_id uuid not null references auth.users (id) on delete cascade,
  terms_version text not null check (char_length(terms_version) between 1 and 40),
  accepted_at timestamptz not null default now(),
  primary key (user_id, terms_version)
);

comment on table public.terms_acceptances is '利用規約への同意記録。同意した版と日時を残す。登録はEdge Functions経由のみ。';

alter table public.terms_acceptances enable row level security;

create policy terms_acceptances_select_own
  on public.terms_acceptances
  for select
  to authenticated
  using (user_id = auth.uid());

grant select on public.terms_acceptances to authenticated;
grant all on public.terms_acceptances to service_role;

-- === ニックネームの同時登録・変更に対する保護 ===
-- 旧名の予約は変更トランザクションのコミット後に見えるため、そのままだと
-- 「Aが旧名Xを手放す」と同時に「BがXを登録」した場合、Bが予約を見逃して取得できてしまう。
-- 関係する正規化名（新旧）を名前単位のアドバイザリロックで直列化し、ロック取得後の
-- 予約チェックが先行トランザクションの結果を必ず見るようにする。
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
    if now() - old.nickname_changed_at < interval '30 days' then
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
