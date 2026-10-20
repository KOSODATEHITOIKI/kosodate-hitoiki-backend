#!/usr/bin/env bash
# データベースのバックアップを取る（データだけ。構造はマイグレーションで作る）。
#
#   SRC_DATABASE_URL=... OUT=./backup-out bash scripts/ops/backup.sh
#
# 出力（OUT）：dump.pgdump（public と auth の一部のデータ）、manifest.json（件数・時刻・ハッシュ）。
# 暗号化・保管は呼び出し側（.github/workflows/backup.yml）が行う。このスクリプトは暗号化前のファイルを作る。
#
# 含めないもの：Storageのファイル（アカウント画像。利用者がいつでも再アップロードでき、削除済みの画像が
# 復元で再公開されないようにするため）、セッション・一時トークン・監査ログ、配信キュー、再送防止キュー。
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

OUT="${OUT:-./backup-out}"
mkdir -p "$OUT"
rm -f "$OUT/dump.pgdump" "$OUT/manifest.json"

# auth のうち、含めないテーブルのデータを除外する指定を作る。
exclude_args=()
while IFS= read -r t; do
  [ -z "$t" ] && continue
  case " $AUTH_KEEP_TABLES " in *" $t "*) continue ;; esac
  exclude_args+=("--exclude-table-data=auth.$t")
done < <(db_psql SRC -c "select table_name from information_schema.tables where table_schema='auth' and table_type='BASE TABLE' order by 1")

log "ダンプを取得（データのみ、public と auth の一部）"
db_dump SRC --format=custom --data-only --no-owner --no-privileges \
  -n public -n auth \
  --exclude-table-data=public.push_deliveries \
  --exclude-table-data=public.request_budget \
  --exclude-table-data=public.idempotency_keys \
  "${exclude_args[@]}" > "$OUT/dump.pgdump"

# 空のダンプを「成功」にしない
size=$(wc -c < "$OUT/dump.pgdump" | tr -d ' ')
if [ "$size" -lt 1000 ]; then
  echo "ダンプが小さすぎます（${size}バイト）。取得に失敗した可能性があります。" >&2
  exit 1
fi

# 復元後に突き合わせるための、主要なテーブルの件数
counts=$(db_psql SRC -c "select json_build_object(
  'auth_users', (select count(*) from auth.users),
  'profiles', (select count(*) from public.profiles),
  'posts', (select count(*) from public.posts),
  'comments', (select count(*) from public.comments),
  'reactions', (select count(*) from public.reactions),
  'saved_posts', (select count(*) from public.saved_posts),
  'blocks', (select count(*) from public.blocks),
  'reports', (select count(*) from public.reports),
  'moderation_actions', (select count(*) from public.moderation_actions),
  'notifications', (select count(*) from public.notifications),
  'admin_users', (select count(*) from public.admin_users),
  'deletion_ledger', (select count(*) from public.deletion_ledger)
)")

hash=$(sha256sum "$OUT/dump.pgdump" | cut -d' ' -f1)
printf '{"dumped_at":"%s","dump_bytes":%s,"dump_sha256":"%s","counts":%s}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$size" "$hash" "$counts" > "$OUT/manifest.json"
log "完了：${size}バイト"
