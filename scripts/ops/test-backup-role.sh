#!/usr/bin/env bash
# 読み取り専用のDBロール（バックアップ・台帳・健康診断が使う）が、正しく動くことを確かめる。
# 手順書（運用手順 4.3）と同じSQL（scripts/ops/backup-reader-role.sql）で、ロールを作って、試す。
#   ①BYPASSRLS つき：運営専用の表の行が見える／pg_dump（auth.users を含む）が通る／書き込めない／健康診断が通る
#   ②BYPASSRLS なし：運営専用の表が「0件」に見える／pg_dump が失敗する／健康診断が、「RLSを回避できない」と失敗する
#      （手順書どおりに作らなかったとき、監視が盲目のまま「正常」と出ることを、防ぐ）
# ローカルのSupabaseだけで使う（使い捨てのロールを作り、最後に消す）。要 supabase start。
set -uo pipefail
cd "$(dirname "$0")"

DB="${DB_CONTAINER:-supabase_db_kosodate-hitoiki-backend}"
P="docker exec $DB psql -U postgres -At -q"
PW="Local-test-$RANDOM$RANDOM"
BY="bk_bypass_test"
NO="bk_nobypass_test"
failed=0
ok() { echo "ok   - $1"; }
ng() { echo "FAIL - $1"; failed=1; }

$P -c "select 1" >/dev/null 2>&1 || { echo "ローカルのDB（$DB）に接続できません。supabase start をしてください" >&2; exit 2; }

cleanup() {
  $P -c "delete from public.app_settings_history where key = 'rls-probe'" >/dev/null 2>&1
  $P -c "drop role if exists $BY" -c "drop role if exists $NO" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

# 手順書と同じSQLで、ロールを作る（名前とパスワードだけ、置き換える）
sed -e "s/backup_reader/$BY/g" -e "s/<強いパスワード>/$PW/" backup-reader-role.sql | docker exec -i "$DB" psql -U postgres -v ON_ERROR_STOP=1 -q >/dev/null || { echo "ロールを作れません" >&2; exit 1; }
# 比較用：BYPASSRLS を付けなかったロール（手順書の、以前の誤った手順）
$P -c "create role $NO login password '$PW'" -c "grant pg_read_all_data to $NO" -c "alter role $NO set default_transaction_read_only = on" >/dev/null || exit 1

# 運営専用の表に、1行（見えるかの目印）
$P -c "insert into public.app_settings_history (key, old_value, new_value) values ('rls-probe', 'null'::jsonb, 'true'::jsonb)" >/dev/null || exit 1

as_role() { # as_role <ロール> <SQL>
  docker exec -e PGPASSWORD="$PW" "$DB" psql -h 127.0.0.1 -U "$1" -d postgres -At -q -c "$2" 2>&1
}
dump_as() { # dump_as <ロール>
  docker exec -e PGPASSWORD="$PW" "$DB" pg_dump -h 127.0.0.1 -U "$1" -d postgres --data-only -t auth.users -t public.app_settings_history 2>&1
}
health_as() { # health_as <ロール>
  # 目印の行（運営設定の変更の記録）が、「24時間の運営設定の変更」の項目に、正しく反応するので、この試験では、そのしきい値だけ、高くする
  SETTING_CHANGES_24H_WARN=1000 SRC_DB_CONTAINER="$DB" SRC_DB_USER="$1" SRC_DB_PASSWORD="$PW" bash ./health-check.sh 2>&1
}

echo "== BYPASSRLS つき（手順書どおり）=="
[ "$(as_role $BY "select count(*) from public.app_settings_history where key = 'rls-probe'")" = "1" ] \
  && ok "運営専用の表の行が、見える" || ng "運営専用の表の行が、見えない（RLSを回避できていない）"
out=$(dump_as $BY); code=$?
[ "$code" = 0 ] && ! grep -qi "row-level security" <<<"$out" \
  && ok "pg_dump（auth.users と運営専用の表）が、通る" || ng "pg_dump が失敗した"
# （出力を変数に入れてから調べる。「コマンド | grep -q」は、pipefailで、誤って失敗になることがある）
out=$(as_role $BY "insert into public.app_settings_history (key, old_value, new_value) values ('write-probe', 'null'::jsonb, 'true'::jsonb)")
grep -qiE "read-only|permission denied" <<<"$out" \
  && ok "書き込めない（読み取り専用）" || ng "書き込めてしまった・想定外の応答"
# 設定を外して（同じ接続で）書き込みを試す。「SET」と「DELETE」を、別の文として送る
out=$(docker exec -e PGPASSWORD="$PW" "$DB" psql -h 127.0.0.1 -U "$BY" -d postgres -At -q -c "set default_transaction_read_only = off" -c "delete from public.app_settings_history" 2>&1)
grep -qiE "permission denied" <<<"$out" \
  && ok "読み取り専用の設定を外しても、書き込む権限がない（二重の鍵）" || ng "読み取り専用の設定を外すと、書き込めてしまった（$out）"
out=$(health_as $BY); code=$?
[ "$code" = 0 ] && grep -q "すべて正常" <<<"$out" && ! grep -q "^ERROR" <<<"$out" \
  && ok "健康診断が、このロールで、通る" || { ng "健康診断が、このロールで、失敗した（終了コード $code）"; echo "$out" | grep -E "^(ERROR|WARN)" | head -3; }

echo "== BYPASSRLS なし（以前の誤った手順）=="
[ "$(as_role $NO "select count(*) from public.app_settings_history where key = 'rls-probe'")" = "0" ] \
  && ok "運営専用の表が、0件に見える（監視が盲目になる状態の再現）" || ng "BYPASSRLS なしでも、行が見えた（試験の前提が崩れている）"
out=$(dump_as $NO); code=$?
[ "$code" != 0 ] && grep -qi "row-level security" <<<"$out" \
  && ok "pg_dump が、RLSのエラーで失敗する" || ng "BYPASSRLS なしでも、pg_dump が通った（試験の前提が崩れている）"
out=$(health_as $NO); code=$?
if [ "$code" = 1 ] && grep -q "^ERROR - このDBロールは、行ごとの権限（RLS）を回避できません" <<<"$out" && ! grep -q "すべて正常" <<<"$out"; then
  ok "健康診断が、『RLSを回避できない』と、はっきり失敗する（盲目のまま『正常』と言わない）"
else
  ng "健康診断が、RLSを回避できないロールを、検出できなかった（終了コード $code）"; echo "$out" | grep -E "^(ERROR|WARN)" | head -3
fi

[ "$failed" = 0 ] && echo "読み取り専用ロールの確認：すべて想定どおり" || { echo "読み取り専用ロールの確認：想定外があります"; exit 1; }
