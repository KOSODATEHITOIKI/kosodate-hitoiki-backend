-- 互換層：Supabase固有の部分（ロール・authスキーマ）を、素のPostgresで代替する。
-- AWS移行の段階1（docs/AWS移行設計案.md）。マイグレーションより前に実行する。
--
-- 本番のAWSでは、Cognitoの利用者IDと対応する auth.users を、post-confirmationで作る。
-- auth.uid() などは、PostgRESTが設定する request.jwt.claims を読む（Supabaseと同じ読み方）。

-- === ロール ===
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  -- Supabase Authの内部ロール。AWSでは使わないが、マイグレーションが権限を付ける箇所があるため置く
  -- （移行が進んだら、マイグレーション側から外す）。
  if not exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    create role supabase_auth_admin nologin noinherit;
  end if;
end
$$;

grant usage on schema public to anon, authenticated, service_role;

-- === スキーマ ===
create schema if not exists auth;
create schema if not exists extensions;
grant usage on schema auth to anon, authenticated, service_role, supabase_auth_admin;
grant usage on schema extensions to anon, authenticated, service_role;

-- 拡張（pgTAPなど）は extensions スキーマに置き、検索パスに含める（Supabaseと同じ）。
-- public に置くと、権限の締め付け（deny-by-default）で、各ロールから呼べなくなる。
alter database postgres set search_path = "$user", public, extensions;

-- === auth.users：利用者ID（Cognitoのsub）と対応する最小のテーブル ===
create table if not exists auth.users (
  id uuid primary key,
  email text,
  phone text,
  raw_user_meta_data jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_sign_in_at timestamptz
);

-- === auth.sessions：セッション（退会の本人確認が、作成時刻を参照する） ===
create table if not exists auth.sessions (
  id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  not_after timestamptz
);

-- === auth.uid()・auth.role()・auth.jwt()：PostgRESTが設定するJWTのクレームを読む ===
-- Supabaseと同じ読み方：単数形の request.jwt.claim.sub を、JSONのclaimsより優先する。
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

create or replace function auth.role()
returns text
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;

create or replace function auth.jwt()
returns jsonb
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')
  )::jsonb
$$;

grant execute on function auth.uid(), auth.role(), auth.jwt() to anon, authenticated, service_role;
