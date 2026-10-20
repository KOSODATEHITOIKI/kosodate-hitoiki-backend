-- 内部ジョブ（プッシュ配信 push-dispatch、画像の削除待ちの処理 storage-cleanup）の定期実行。
--
-- DBの中の pg_cron が、pg_net（DBからHTTPを呼ぶ拡張）で、Edge Functions を呼ぶ。
-- 呼び出しの秘密（INTERNAL_JOB_SECRET）は、Supabase Vault（暗号化された保管庫）に置く。コード・リポジトリ・
-- GitHubには置かない。Edge Functions側も同じ値をシークレットとして持つ（docs/運用手順.md の「内部ジョブ」）。
--
-- Vault・pg_net がない環境（Supabase以外）や、秘密が未登録の環境では、何も呼ばずに終わる（安全側）。

-- pg_net が使える環境（Supabase）でだけ有効にする。
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net with schema extensions;
  end if;
end
$$;

-- 内部ジョブを呼ぶ。許可した名前だけ（任意のURLは呼ばない）。
-- 返り値：pg_net のリクエストID。呼べない（未設定・拡張なし）ときは null。
create or replace function public.invoke_internal_job(p_name text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  base_url text;
  job_secret text;
  request_id bigint;
begin
  if p_name not in ('push-dispatch', 'storage-cleanup') then
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
  end if;

  -- Vault・pg_net がない環境では、何もしない。
  if to_regclass('vault.decrypted_secrets') is null or to_regnamespace('net') is null then
    return null;
  end if;

  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1' into base_url using 'project_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1' into job_secret using 'internal_job_secret';

  -- 秘密が未登録のときは何もしない（登録するまで、ジョブは動かない）。
  if base_url is null or job_secret is null then
    return null;
  end if;

  execute
    'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 20000)'
  into request_id
  using
    rtrim(base_url, '/') || '/functions/v1/' || p_name,
    jsonb_build_object('Content-Type', 'application/json', 'x-job-secret', job_secret),
    '{}'::jsonb;

  return request_id;
end;
$$;

comment on function public.invoke_internal_job(text) is
  '内部ジョブ（push-dispatch・storage-cleanup）をEdge Functions経由で呼ぶ。pg_cronだけが呼ぶ。秘密と接続先はVaultから読む。未設定なら何もしない。';

-- cron（postgresロール）だけが呼ぶ。利用者・APIからは呼べない。
revoke all on function public.invoke_internal_job(text) from public, anon, authenticated, service_role;

-- 定期実行：配信は1分ごと、画像の削除待ちは10分ごと。
select cron.schedule('internal-job-push-dispatch', '* * * * *', $$select public.invoke_internal_job('push-dispatch')$$);
select cron.schedule('internal-job-storage-cleanup', '*/10 * * * *', $$select public.invoke_internal_job('storage-cleanup')$$);
