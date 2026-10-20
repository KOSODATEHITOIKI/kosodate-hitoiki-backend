-- 内部ジョブの秘密を、Vaultだけに置く（唯一の保管場所）。
--
-- 以前は、同じ秘密を「Vault」と「Edge Functionsのシークレット」の2か所に手でコピーして揃える必要があり、
-- 貼り付けのずれで食い違いが起きた。今後は、秘密はDBの中で作ってVaultにだけ置き、誰も値を見ない。
-- Edge Functionsは、受け取った秘密が正しいかを、DBに問い合わせて確かめる（job_secret_valid）。
-- 管理者は、SQL Editorで setup_internal_jobs を実行するだけでよい（コピー・貼り付けは不要）。

-- 受け取った秘密が、Vaultの秘密と一致するか。Edge Functions（service_role）だけが呼ぶ。
-- 形式（64桁の16進数）でない入力は、Vaultを読まずに拒否する。
create or replace function public.job_secret_valid(p_given text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  expected text;
begin
  if p_given is null or p_given !~ '^[0-9a-f]{64}$' then
    return false;
  end if;
  if to_regclass('vault.decrypted_secrets') is null then
    return false;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
    into expected using 'internal_job_secret';
  return expected is not null and expected = p_given;
end;
$$;

comment on function public.job_secret_valid(text) is
  '内部ジョブの秘密が正しいか。秘密はVaultにだけある。service_roleだけが呼ぶ。';

-- 管理者が、SQL Editorで1回実行する設定。秘密をDBの中で作ってVaultに置き、接続先も登録する。
-- すでにあれば、秘密は変えない（p_rotate が true のときだけ、新しい秘密に入れ替える）。
-- 秘密の値は、返さない。
create or replace function public.setup_internal_jobs(p_project_url text, p_rotate boolean default false)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  new_secret text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  secret_id uuid;
  url_id uuid;
  result text;
begin
  if to_regclass('vault.secrets') is null then
    raise exception 'VAULT_REQUIRED' using errcode = 'P0001';
  end if;
  if p_project_url is null or p_project_url !~ '^https://[a-z0-9-]+\.supabase\.co/?$' then
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001', detail = 'p_project_url は https://<ref>.supabase.co の形';
  end if;

  execute 'select id from vault.secrets where name = $1' into secret_id using 'internal_job_secret';
  if secret_id is null then
    perform vault.create_secret(new_secret, 'internal_job_secret');
    result := '秘密を新しく作りました';
  elsif p_rotate then
    perform vault.update_secret(secret_id, new_secret);
    result := '秘密を入れ替えました';
  else
    result := '秘密はすでにあります（変更しません）';
  end if;

  execute 'select id from vault.secrets where name = $1' into url_id using 'project_url';
  if url_id is null then
    perform vault.create_secret(rtrim(p_project_url, '/'), 'project_url');
  else
    perform vault.update_secret(url_id, rtrim(p_project_url, '/'));
  end if;

  return result || '。接続先：' || rtrim(p_project_url, '/');
end;
$$;

comment on function public.setup_internal_jobs(text, boolean) is
  '内部ジョブの設定（管理者がSQL Editorで実行）。秘密をDBの中で作ってVaultに置く。秘密の値は返さない。';

-- 権限：job_secret_valid は service_role だけ。setup_internal_jobs は、DBの管理者（postgres）だけ。
revoke all on function public.job_secret_valid(text) from public, anon, authenticated;
grant execute on function public.job_secret_valid(text) to service_role;
revoke all on function public.setup_internal_jobs(text, boolean) from public, anon, authenticated, service_role;
