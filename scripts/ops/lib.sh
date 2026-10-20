#!/usr/bin/env bash
# バックアップ・復元・監視のスクリプトの共通部分。
#
# 接続先は「SRC」（バックアップの取得元・監視の対象）と「DST」（復元先）の2つ。それぞれ、次のどちらかで指定する：
#   <SIDE>_DB_CONTAINER   ローカルのSupabaseのDBコンテナ名（例：supabase_db_kosodate-hitoiki-backend）
#   <SIDE>_DATABASE_URL   接続文字列（クラウド。パスワードを含む秘密情報。ログに出さない）
# クラウドのDBへは、PostgreSQL 17のクライアント（dockerイメージ）で接続する。
# 秘密情報（接続文字列）は、環境変数でだけ受け取る。引数や標準出力に出さない。

set -euo pipefail

PG_IMAGE="${PG_IMAGE:-postgres:17}"

_conn() { # _conn <SIDE> → container:<名前> または url:<変数名>
  local side="$1" c u
  c="${side}_DB_CONTAINER"
  u="${side}_DATABASE_URL"
  if [ -n "${!c:-}" ]; then echo "container"; elif [ -n "${!u:-}" ]; then echo "url"; else
    echo "${side} の接続先が未設定です（${side}_DB_CONTAINER か ${side}_DATABASE_URL）" >&2
    return 2
  fi
}

# db_psql <SIDE> [psqlの引数...]：標準入力のSQLも使える。値だけを出力する（-t -A）。
db_psql() {
  local side="$1"
  shift
  local c="${side}_DB_CONTAINER" u="${side}_DATABASE_URL"
  case "$(_conn "$side")" in
    container) docker exec -i "${!c}" psql -U postgres -v ON_ERROR_STOP=1 -q -t -A "$@" ;;
    url) docker run --rm -i "$PG_IMAGE" psql "${!u}" -v ON_ERROR_STOP=1 -q -t -A "$@" ;;
  esac
}

# db_dump <SIDE> [pg_dumpの引数...]：標準出力へダンプを出す。
db_dump() {
  local side="$1"
  shift
  local c="${side}_DB_CONTAINER" u="${side}_DATABASE_URL"
  case "$(_conn "$side")" in
    container) docker exec -i "${!c}" pg_dump -U postgres "$@" ;;
    url) docker run --rm -i "$PG_IMAGE" pg_dump --dbname="${!u}" "$@" ;;
  esac
}

# db_restore <SIDE> [pg_restoreの引数...]：標準入力からダンプを読む。
db_restore() {
  local side="$1"
  shift
  local c="${side}_DB_CONTAINER" u="${side}_DATABASE_URL"
  case "$(_conn "$side")" in
    container) docker exec -i "${!c}" pg_restore -U postgres -d postgres "$@" ;;
    url) docker run --rm -i "$PG_IMAGE" pg_restore --dbname="${!u}" "$@" ;;
  esac
}

log() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }

# バックアップに含めない認証のテーブル（セッション・一時トークン・監査ログなど）。
# 含めるのは auth.users・auth.identities・auth.mfa_factors だけ。セッションを復元しないので、復元後は全員が
# 再ログインする（削除済み・盗まれたセッションが復活しない）。新しい認証テーブルが増えても、自動で除外される。
AUTH_KEEP_TABLES="users identities mfa_factors"
