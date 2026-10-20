#!/usr/bin/env bash
# 取得したバックアップを、使い捨ての環境に復元して、件数が元と一致することを確かめる。
#
#   DST_DB_CONTAINER=... bash scripts/ops/verify-backup.sh <backup-out>
#
# 復元できないバックアップは、バックアップではない。取得のたびに実行して、失敗したらバックアップの失敗として扱う。
# 復元先は、マイグレーションを適用済みの使い捨てのDB（ローカルのSupabase）。本番・devには向けない。
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

DIR="${1:?使い方: verify-backup.sh <backup-out>}"
[ -s "$DIR/dump.pgdump" ] && [ -s "$DIR/manifest.json" ] || { echo "バックアップが見つかりません: $DIR" >&2; exit 1; }
[ -n "${DST_DB_CONTAINER:-}" ] || { echo "復元先は、使い捨てのローカルDB（DST_DB_CONTAINER）に限ります" >&2; exit 2; }

expected_hash=$(sed -n 's/.*"dump_sha256":"\([0-9a-f]*\)".*/\1/p' "$DIR/manifest.json")
actual_hash=$(sha256sum "$DIR/dump.pgdump" | cut -d' ' -f1)
[ "$expected_hash" = "$actual_hash" ] || { echo "ダンプのハッシュが一致しません" >&2; exit 1; }

# 復元（台帳による再削除は、件数の突き合わせのあとに別で確かめる。ここでは行わない）
bash ./restore.sh "$DIR/dump.pgdump" >/dev/null

KEYS="auth_users profiles posts comments reactions saved_posts blocks reports moderation_actions notifications admin_users deletion_ledger"
actual=$(db_psql DST -c "select json_build_object(
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

# manifest の counts_before / counts_after の範囲に、復元後の件数が収まること
# （ダンプの途中で件数が変わっても、誤って失敗にしない）
num() { # num <JSON> <キー> <セクション（省略可）>
  local json="$1" key="$2" section="${3:-}"
  if [ -n "$section" ]; then json=$(echo "$json" | sed -n "s/.*\"$section\":\({[^}]*}\).*/\1/p"); fi
  echo "$json" | sed -n "s/.*\"$key\" *: *\([0-9]*\).*/\1/p"
}
manifest=$(tr -d '\n' < "$DIR/manifest.json")
fail=0
for key in $KEYS; do
  b=$(num "$manifest" "$key" counts_before)
  a=$(num "$manifest" "$key" counts_after)
  r=$(num "$actual" "$key")
  if [ -z "$b" ] || [ -z "$a" ] || [ -z "$r" ]; then echo "件数を読めません：$key" >&2; fail=1; continue; fi
  lo=$(( b < a ? b : a )); hi=$(( b > a ? b : a ))
  if [ "$r" -lt "$lo" ] || [ "$r" -gt "$hi" ]; then
    echo "不一致：$key（バックアップ時 ${lo}〜${hi} / 復元後 ${r}）" >&2
    fail=1
  fi
done
[ "$fail" = 0 ] || exit 1
log "復元の検証に成功：件数が一致"
