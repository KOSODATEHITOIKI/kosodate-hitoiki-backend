#!/usr/bin/env bash
# 削除の台帳（IDと時刻だけ）を書き出す。バックアップの取得後に削除されたものを、DBごと失っても追えるように、
# 1時間ごとに別の場所へ保管する（暗号化・保管は呼び出し側）。復元のあと、restore.sh に渡して削除をやり直す。
#
#   SRC_DATABASE_URL=... OUT=./ledger.json bash scripts/ops/ledger-export.sh
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

OUT="${OUT:-./ledger.json}"
db_psql SRC -c "select coalesce(json_agg(json_build_object('kind', kind, 'target_id', target_id, 'deleted_at', deleted_at) order by deleted_at), '[]'::json) from public.deletion_ledger" > "$OUT"
[ -s "$OUT" ] || { echo "台帳の書き出しに失敗しました" >&2; exit 1; }
log "台帳を書き出した：$(grep -o 'target_id' "$OUT" | wc -l | tr -d ' ')件"
