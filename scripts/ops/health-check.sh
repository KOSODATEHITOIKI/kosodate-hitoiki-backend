#!/usr/bin/env bash
# 運用の健康診断。しきい値を超えたものがあれば、理由を表示して失敗（終了コード1）にする。
# 毎日、.github/workflows/health-check.yml から実行する（失敗すると、GitHubからメールが届く）。
#
#   SRC_DATABASE_URL=...（読み取り専用ロールの接続文字列） bash scripts/ops/health-check.sh
#
# ログ・出力には、個人情報（本文・メール・ニックネーム）を出さない。件数と、IDを含まないラベルだけ。
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

# しきい値（環境変数で変えられる）。無料枠・運用の目安。
DB_SIZE_WARN_MB="${DB_SIZE_WARN_MB:-400}"          # 無料プランのDBは500MB。80%で警告
USERS_WARN="${USERS_WARN:-40000}"                  # 月間アクティブ5万人の無料枠の80%（登録者数で代用）
REPORT_OVERDUE_DAYS="${REPORT_OVERDUE_DAYS:-3}"    # 未対応の通報が、この日数を超えたら警告
STORAGE_PENDING_WARN="${STORAGE_PENDING_WARN:-1}"  # 削除待ちで、5回以上失敗した画像の件数
PUSH_FAILED_WARN="${PUSH_FAILED_WARN:-20}"         # 24時間のプッシュ配信の失敗数

warn=0
check() { # check <ラベル> <値> <しきい値> <説明>
  if [ "$2" -ge "$3" ]; then
    echo "WARN  - $1：$2（しきい値 $3）$4"
    warn=1
  else
    echo "ok    - $1：$2（しきい値 $3）"
  fi
}
q() { db_psql SRC -c "$1"; }

check "DBの容量（MB）" "$(q "select (pg_database_size(current_database()) / 1024 / 1024)::int")" "$DB_SIZE_WARN_MB" \
  "→ 無料枠の上限に近い。古いデータの整理か、プランの見直しを検討"
check "登録者数" "$(q "select count(*) from auth.users")" "$USERS_WARN" \
  "→ 月間アクティブの無料枠に近い可能性"
check "未対応で${REPORT_OVERDUE_DAYS}日を超えた通報" \
  "$(q "select count(distinct (target_type, target_id)) from public.reports where resolved_at is null and created_at < now() - interval '${REPORT_OVERDUE_DAYS} days'")" 1 \
  "→ 運営の対応が遅れている"
check "削除に5回以上失敗している画像（公開されたまま残る恐れ）" \
  "$(q "select count(*) from public.pending_storage_deletions where attempts >= 5")" "$STORAGE_PENDING_WARN" \
  "→ storage-cleanup が動いていないか、Storageの障害。至急確認"
check "1日以上削除されていない画像" \
  "$(q "select count(*) from public.pending_storage_deletions where created_at < now() - interval '1 day' and next_attempt_at < now()")" 1 \
  "→ 削除ジョブ（storage-cleanup）の定期実行が止まっている可能性"
check "24時間のプッシュ配信の失敗数" \
  "$(q "select count(*) from public.push_deliveries where status = 'failed' and created_at > now() - interval '24 hours'")" "$PUSH_FAILED_WARN" \
  "→ FCMの設定・障害を確認"
check "配信されないまま溜まったプッシュ（1時間以上）" \
  "$(q "select count(*) from public.push_deliveries where status = 'pending' and next_attempt_at < now() - interval '1 hour'")" 1 \
  "→ push-dispatch の定期実行が止まっている可能性"
check "保持期限（35日）を過ぎても残っている台帳の行" \
  "$(q "select count(*) from public.deletion_ledger where deleted_at < now() - interval '35 days'")" 1 \
  "→ 保持期限を過ぎた台帳が残っている（毎日の掃除が止まっている可能性）"

# 毎日の掃除（pg_cron）が動いているか：最近の実行の失敗数。cronスキーマを読めない権限では飛ばす。
if [ "$(q "select to_regclass('cron.job_run_details') is not null")" = "t" ]; then
  failed=$(q "select count(*) from cron.job_run_details where status = 'failed' and start_time > now() - interval '48 hours'" 2>/dev/null || echo "")
  if [ -n "$failed" ]; then check "48時間の定期実行（pg_cron）の失敗数" "$failed" 1 "→ 共感のまとめ通知・期限切れの削除などが失敗している"; fi
fi

if [ "$warn" = 1 ]; then
  echo "要確認の項目があります（docs/運用手順.md の「監視」を参照）" >&2
  exit 1
fi
echo "すべて正常"
