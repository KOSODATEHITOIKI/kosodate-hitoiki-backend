#!/usr/bin/env bash
# バックアップを復元する。復元先に、先にマイグレーションを適用しておくこと（構造はマイグレーションで作る）。
#
#   DST_DB_CONTAINER=... bash scripts/ops/restore.sh <dump.pgdump> [ledger.json]
#
# 復元先の既存のデータは削除される。**本番には、手順書（docs/運用手順.md）の確認を済ませてから実行する。**
# ledger.json を渡すと、台帳（バックアップの取得後に削除されたもの）を取り込み、削除をやり直す
# （削除済みのデータが復元で再公開されないようにする）。
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

DUMP="${1:?使い方: restore.sh <dump.pgdump> [ledger.json]}"
LEDGER="${2:-}"
[ -s "$DUMP" ] || { echo "ダンプが見つかりません: $DUMP" >&2; exit 1; }

log "ユーザー定義のトリガーを一時的に止める（復元中に、通知・自動非表示・検証が動かないように）"
db_psql DST <<'SQL'
do $$
declare t record;
begin
  for t in select schemaname, tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table %I.%I disable trigger user', t.schemaname, t.tablename);
  end loop;
end $$;
SQL

# トリガーを元に戻す。データの投入が終わったらすぐ（台帳による再削除より前に）戻す。失敗した場合も、必ず戻す
restore_triggers() {
  db_psql DST <<'SQL'
do $$
declare t record;
begin
  for t in select schemaname, tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table %I.%I enable trigger user', t.schemaname, t.tablename);
  end loop;
end $$;
SQL
}
trap restore_triggers EXIT

log "復元先の既存のデータを削除"
db_psql DST <<'SQL'
do $$
declare names text;
begin
  select string_agg(format('%I.%I', schemaname, tablename), ', ') into names
  from pg_tables where schemaname = 'public';
  execute 'truncate table ' || names || ' cascade';
end $$;
delete from auth.users;
SQL

log "データを復元"
db_restore DST --data-only --no-owner --no-privileges --exit-on-error < "$DUMP"

log "ユーザー定義のトリガーを元に戻す（再削除では、コメントの本文を消すトリガー等が動く必要がある）"
restore_triggers
trap - EXIT

if [ -n "$LEDGER" ]; then
  [ -s "$LEDGER" ] || { echo "台帳が見つかりません: $LEDGER" >&2; exit 1; }
  log "台帳を取り込み、削除をやり直す"
  rows=$(tr -d '\n' < "$LEDGER" | sed "s/'/''/g")
  imported=$(db_psql DST -c "select public.import_deletion_ledger('${rows}'::jsonb)")
  replayed=$(db_psql DST -c "select public.replay_deletion_ledger()")
  log "台帳：取り込み ${imported}件、再削除 ${replayed}"
else
  log "台帳は渡されていません。バックアップの取得後に削除されたデータが復活している可能性があります。"
  log "（台帳がなくても、復元後に replay_deletion_ledger() で、バックアップに含まれる台帳の分は再削除できます）"
  replayed=$(db_psql DST -c "select public.replay_deletion_ledger()")
  log "バックアップに含まれる台帳による再削除：${replayed}"
fi
log "復元が完了"
