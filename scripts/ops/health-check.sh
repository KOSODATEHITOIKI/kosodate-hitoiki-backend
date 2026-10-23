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
# 侵入・荒らしの兆候（初期値は控えめ。利用者が増えたら、いつもの数に合わせて調整する）
SIGNUPS_24H_WARN="${SIGNUPS_24H_WARN:-50}"         # 24時間の新規登録数（ボットによる大量の登録）
NEW_ADMINS_24H_WARN="${NEW_ADMINS_24H_WARN:-1}"    # 24時間に追加された運営者（運営の権限を足された）
SETTING_CHANGES_24H_WARN="${SETTING_CHANGES_24H_WARN:-1}"  # 24時間の運営設定の変更（新規登録の停止などの書き換え）
MODERATION_24H_WARN="${MODERATION_24H_WARN:-20}"   # 24時間の運営の対処の数（運営アカウントの乗っ取りによる大量の削除）
DELETIONS_24H_WARN="${DELETIONS_24H_WARN:-100}"    # 24時間の削除の数（台帳。大量削除）

warn=0
failed_query=0
check() { # check <ラベル> <値> <しきい値> <説明>
  # 値が数でない（空・エラー）は、DBへの問い合わせの失敗。「正常」と取り違えず、失敗として扱う。
  if ! [[ "$2" =~ ^[0-9]+$ ]]; then
    echo "ERROR - $1：値を取得できませんでした（DBへの接続・権限・SQLの失敗の可能性）" >&2
    failed_query=1
    return
  fi
  if [ "$2" -ge "$3" ]; then
    echo "WARN  - $1：$2（しきい値 $3）$4"
    warn=1
  else
    echo "ok    - $1：$2（しきい値 $3）"
  fi
}
# 失敗したときは、何も出力せず（空）、理由は標準エラーへ。呼び出し側（check）が、数でない値を失敗として扱う。
q() { db_psql SRC -c "$1" || true; }

# 最初に、読んでいるロールが、行ごとの権限（RLS）を回避できるか確かめる。
# 回避できないと、運営専用・内部専用の表（通報・運営の対処・削除待ち・配信・台帳など）が、いつも「0件」に見えて、
# 異常があっても「正常」と出てしまう（監視が盲目になる）。読み取り専用ロールには、BYPASSRLS が要る（運用手順 4.3）。
rls_ok="$(q "select (rolbypassrls or rolsuper) from pg_roles where rolname = current_user")"
case "$rls_ok" in
  t) ;;
  f)
    echo "ERROR - このDBロールは、行ごとの権限（RLS）を回避できません。運営専用・内部専用の表が、0件に見えて、監視が正しく動きません" >&2
    echo "        → 読み取り専用ロールに BYPASSRLS を付ける（運用手順 4.3、scripts/ops/backup-reader-role.sql）" >&2
    failed_query=1
    ;;
  *)
    echo "ERROR - DBロールの権限を確認できませんでした（DBへの接続・権限の失敗の可能性）" >&2
    failed_query=1
    ;;
esac

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

# --- 侵入・荒らしの兆候（意図したものでない変化に、気づくため）---
check "24時間の新規登録数（ボットの兆候）" \
  "$(q "select count(*) from auth.users where created_at > now() - interval '24 hours'")" "$SIGNUPS_24H_WARN" \
  "→ いつもより多い。ボットの可能性。Authentication > Attack Protection（CAPTCHA）と、新規登録の停止（運営設定）を検討"
check "24時間に追加された運営者（運営の権限）" \
  "$(q "select count(*) from public.admin_users where created_at > now() - interval '24 hours'")" "$NEW_ADMINS_24H_WARN" \
  "→ 運営者が増えた。意図した追加でなければ、侵入の可能性。すぐ確認（運用手順の事故対応）"
check "24時間の運営設定の変更" \
  "$(q "select count(*) from public.app_settings_history where changed_at > now() - interval '24 hours'")" "$SETTING_CHANGES_24H_WARN" \
  "→ 新規登録の停止・投稿の制限などが書き換えられた。意図した変更か確認（誰が変えたかは、app_settings_history）"
check "24時間の運営の対処の数（削除・警告・利用停止）" \
  "$(q "select count(*) from public.moderation_actions where created_at > now() - interval '24 hours'")" "$MODERATION_24H_WARN" \
  "→ いつもより多い。運営アカウントの乗っ取りによる、大量の対処の可能性（誰がしたかは、moderation_actions）"
check "24時間の削除の数（台帳）" \
  "$(q "select count(*) from public.deletion_ledger where deleted_at > now() - interval '24 hours'")" "$DELETIONS_24H_WARN" \
  "→ 大量の削除（退会・投稿・コメント）。意図しないものでないか確認"

# 毎日の掃除（pg_cron）が動いているか：最近の実行の失敗数。cronスキーマを読めない権限では飛ばす。
has_cron="$(q "select to_regclass('cron.job_run_details') is not null")"
case "$has_cron" in
  t)
    failed=$(q "select count(*) from cron.job_run_details where status = 'failed' and start_time > now() - interval '48 hours'" 2>/dev/null)
    if [[ "$failed" =~ ^[0-9]+$ ]]; then
      check "48時間の定期実行（pg_cron）の失敗数" "$failed" 1 "→ 共感のまとめ通知・期限切れの削除などが失敗している"
    else
      echo "skip  - 48時間の定期実行（pg_cron）の失敗数：読み取れないので確認を飛ばした（読み取り専用の権限では、cronスキーマを読めない）"
    fi
    ;;
  f) echo "skip  - 定期実行（pg_cron）の確認：cronスキーマがない環境" ;;
  *) echo "ERROR - 定期実行（pg_cron）の有無を確認できませんでした（DBへの問い合わせの失敗の可能性）" >&2; failed_query=1 ;;
esac

# DBに問い合わせられなかった項目があれば、「正常」とは言わず、失敗にする（監視が止まっていることに、気づけるように）。
if [ "$failed_query" = 1 ]; then
  echo "DBへの問い合わせに失敗した項目があります。接続文字列・権限・DBの状態を確認してください" >&2
  exit 1
fi

if [ "$warn" = 1 ]; then
  echo "要確認の項目があります（docs/運用手順.md の「監視」を参照）" >&2
  exit 1
fi
echo "すべて正常"
