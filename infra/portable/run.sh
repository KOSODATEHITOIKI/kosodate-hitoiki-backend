#!/usr/bin/env bash
# Supabaseなしの素のPostgres 17で、全マイグレーションとpgTAPを通せるか確かめる（AWS移行の段階1）。
#
#   bash infra/portable/run.sh            # 全マイグレーションを適用し、pgTAPを実行
#   KEEP=1 bash infra/portable/run.sh     # 終わってもコンテナを残す（調査用）
#   SKIP_TESTS=1 …                        # マイグレーションまで適用して、pgTAPは実行しない
#
# 前提：Docker。イメージは初回に自動で作る。ローカル専用（本番・クラウドには向けない）。
set -uo pipefail
cd "$(dirname "$0")/../.."

IMAGE=kosodate-portable-pg
NAME=kosodate-portable-pg-test
PORT="${PORT:-54999}"
docker build -q -t "$IMAGE" infra/portable >/dev/null || exit 1
docker rm -f "$NAME" >/dev/null 2>&1

docker run -d --name "$NAME" -e POSTGRES_PASSWORD=postgres -p "$PORT:5432" "$IMAGE" \
  -c shared_preload_libraries=pg_cron -c cron.database_name=postgres >/dev/null || exit 1
cleanup() { [ "${KEEP:-}" = 1 ] || docker rm -f "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT

psql_in() { docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }

for _ in $(seq 1 60); do
  docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
sleep 2 # 初期化後の再起動を待つ

echo "== 互換層を適用 =="
psql_in < infra/portable/compat.sql || { echo "FAIL - 互換層"; exit 1; }
psql_in -c "create extension if not exists pgtap with schema extensions;" || exit 1

echo "== マイグレーションを適用 =="
FAILED_MIG=0
for f in supabase/migrations/*.sql; do
  if psql_in < "$f" >/dev/null 2>"/tmp/portable_err.txt"; then
    echo "ok   - $(basename "$f")"
  else
    echo "FAIL - $(basename "$f")"
    head -5 /tmp/portable_err.txt | sed 's/^/       /'
    FAILED_MIG=1
    break
  fi
done
[ "$FAILED_MIG" = 0 ] || { echo "マイグレーションの適用に失敗しました"; exit 1; }

if [ -f supabase/seed.sql ]; then psql_in < supabase/seed.sql >/dev/null || echo "FAIL - seed"; fi

# SKIP_TESTS=1：DBの準備だけをして終わる（rest.sh などが、準備済みのDBを使うため）
[ "${SKIP_TESTS:-}" = 1 ] && exit 0

echo "== pgTAP =="
MSYS_NO_PATHCONV=1 docker cp supabase/tests "$NAME:/tests" >/dev/null
MSYS_NO_PATHCONV=1 docker exec "$NAME" pg_prove -U postgres -d postgres --ext .sql -r /tests 2>&1 | tail -60
exit "${PIPESTATUS[0]}"
