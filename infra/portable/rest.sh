#!/usr/bin/env bash
# PostgREST（AWSではFargateで動かすAPI層）を、素のPostgres 17の上でローカルに動かし、
# 実際のHTTPのAPIとして、権限が守られていることを確かめる（AWS移行の段階2）。
#
#   bash infra/portable/rest.sh
#
# 前提：Docker。ローカル専用。費用はかからない。PostgRESTは、Supabaseが使うのと同じ版（16.3）に固定している。
# 本番のAWSでは、JWTの検証をCognitoのJWKSで行う（ここではテスト用の共有鍵）。それ以外の権限の仕組み
# （ロール・RLS・列の権限・関数の権限）は、本番と同じものを検証する。
set -uo pipefail
cd "$(dirname "$0")/../.."

PGREST_IMAGE="postgrest/postgrest:v16.3"
PG=kosodate-portable-pg-test
REST=kosodate-portable-postgrest
NET=kosodate-portable-net
REST_PORT="${REST_PORT:-54998}"
# テスト専用の使い捨ての鍵（本番の鍵ではない）
JWT_SECRET="local-test-only-jwt-secret-0123456789abcdef-$(date +%s)"
AUTH_PW="authenticator-local-test-$(date +%s)"

cleanup() {
  docker rm -f "$REST" >/dev/null 2>&1
  docker rm -f "$PG" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

echo "== DB（素のPostgres 17、互換層、全マイグレーション）=="
KEEP=1 SKIP_TESTS=1 bash infra/portable/run.sh 2>&1 | grep -E "FAIL|失敗" && { echo "DBの準備に失敗しました"; exit 1; }

docker network create "$NET" >/dev/null
docker network connect "$NET" "$PG"

# APIが使う接続ロール（authenticator）。権限を持たず、リクエストごとにanon/authenticatedへ切り替わる。
docker exec -i "$PG" psql -U postgres -v ON_ERROR_STOP=1 -q <<SQL || exit 1
do \$\$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator login noinherit;
  end if;
end \$\$;
alter role authenticator with password '${AUTH_PW}';
grant anon, authenticated, service_role to authenticator;
SQL

echo "== PostgREST（v16.3）を起動 =="
docker run -d --name "$REST" --network "$NET" -p "${REST_PORT}:3000" \
  -e PGRST_DB_URI="postgres://authenticator:${AUTH_PW}@${PG}:5432/postgres" \
  -e PGRST_DB_SCHEMAS=public \
  -e PGRST_DB_ANON_ROLE=anon \
  -e PGRST_DB_EXTRA_SEARCH_PATH=public,extensions \
  -e PGRST_JWT_SECRET="$JWT_SECRET" \
  -e PGRST_JWT_AUD=authenticated \
  -e PGRST_SERVER_PORT=3000 \
  "$PGREST_IMAGE" >/dev/null || exit 1

for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${REST_PORT}/topics?limit=1")
  [ "$code" = "200" ] && break
  sleep 1
done
[ "$code" = "200" ] || { echo "PostgRESTが起動しません"; docker logs "$REST" 2>&1 | tail -5; exit 1; }

echo "== 権限の確認（HTTP）=="
REST_URL="http://127.0.0.1:${REST_PORT}" JWT_SECRET="$JWT_SECRET" \
  PSQL="docker exec -i $PG psql -U postgres -v ON_ERROR_STOP=1 -q" \
  node infra/portable/rest-tests.mjs
