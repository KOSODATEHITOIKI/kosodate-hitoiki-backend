#!/usr/bin/env bash
# バックアップ・復元・監視のスクリプトの共通部分。
#
# 接続先は「SRC」（バックアップの取得元・監視の対象）と「DST」（復元先）の2つ。それぞれ、次のどちらかで指定する：
#   <SIDE>_DB_CONTAINER   ローカルのSupabaseのDBコンテナ名（例：supabase_db_kosodate-hitoiki-backend）
#                         （任意：<SIDE>_DB_USER・<SIDE>_DB_PASSWORD を付けると、そのロールで接続する。読み取り専用ロールの試験用。
#                          付けなければ、管理者のpostgresで接続する）
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

# _container_exec <SIDE> <コマンド> [引数...]：ローカルのコンテナで、psql・pg_dump を実行する。
# <SIDE>_DB_USER があれば、そのロールで（パスワードで、TCP経由）、なければ、postgresで接続する。
_container_exec() {
  local side="$1" cmd="$2"
  shift 2
  local c="${side}_DB_CONTAINER" user="${side}_DB_USER" pw="${side}_DB_PASSWORD"
  if [ -n "${!user:-}" ]; then
    docker exec -i -e PGPASSWORD="${!pw:-}" "${!c}" "$cmd" -h 127.0.0.1 -U "${!user}" -d postgres "$@"
  else
    docker exec -i "${!c}" "$cmd" -U postgres "$@"
  fi
}

# db_psql <SIDE> [psqlの引数...]：標準入力のSQLも使える。値だけを出力する（-t -A）。
db_psql() {
  local side="$1"
  shift
  local c="${side}_DB_CONTAINER" u="${side}_DATABASE_URL"
  case "$(_conn "$side")" in
    container) _container_exec "$side" psql -v ON_ERROR_STOP=1 -q -t -A "$@" ;;
    url) docker run --rm -i "$PG_IMAGE" psql "${!u}" -v ON_ERROR_STOP=1 -q -t -A "$@" ;;
  esac
}

# db_dump <SIDE> [pg_dumpの引数...]：標準出力へダンプを出す。
db_dump() {
  local side="$1"
  shift
  local c="${side}_DB_CONTAINER" u="${side}_DATABASE_URL"
  case "$(_conn "$side")" in
    container) _container_exec "$side" pg_dump "$@" ;;
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
