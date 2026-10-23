#!/usr/bin/env bash
# 監視（health-check.sh）の動きを確かめる。「異常を、正常と取り違えない」ことが目的。
#   ①正常なとき：すべて ok で、終了コード 0
#   ②DBに問い合わせられないとき：ERROR を出して、終了コード 1（「すべて正常」とは言わない）
#   ③しきい値を超えたとき：WARN を出して、終了コード 1
# 要 supabase start（ローカルのDBのコンテナを使う）。
set -uo pipefail
cd "$(dirname "$0")"

DB="${DB_CONTAINER:-supabase_db_kosodate-hitoiki-backend}"
failed=0
ok() { echo "ok   - $1"; }
ng() { echo "FAIL - $1"; failed=1; }

out=$(SRC_DB_CONTAINER="$DB" bash ./health-check.sh 2>&1); code=$?
if [ "$code" = 0 ] && grep -q "すべて正常" <<<"$out" && ! grep -qE "^(ERROR|WARN)" <<<"$out"; then
  ok "正常なとき：すべて ok、終了コード 0"
else
  ng "正常なときに、失敗した（終了コード $code）"; echo "$out" | tail -5
fi

out=$(SRC_DB_CONTAINER="no-such-container-for-test" bash ./health-check.sh 2>&1); code=$?
if [ "$code" != 0 ] && grep -q "^ERROR" <<<"$out" && ! grep -q "すべて正常" <<<"$out" && ! grep -qE "^ok " <<<"$out"; then
  ok "DBに問い合わせられないとき：ERROR を出して、失敗（『すべて正常』とも ok とも言わない）"
else
  ng "DBに問い合わせられないのに、失敗として扱われていない（終了コード $code）"; echo "$out" | tail -5
fi

out=$(SRC_DB_CONTAINER="$DB" DB_SIZE_WARN_MB=0 bash ./health-check.sh 2>&1); code=$?
if [ "$code" = 1 ] && grep -q "^WARN" <<<"$out" && ! grep -q "すべて正常" <<<"$out"; then
  ok "しきい値を超えたとき：WARN を出して、失敗"
else
  ng "しきい値を超えたのに、失敗として扱われていない（終了コード $code）"; echo "$out" | tail -5
fi

# 侵入・荒らしの兆候の項目が、しきい値で、それぞれ検出されること（ローカルは、0件なので、しきい値を0にして確かめる）
for var in SIGNUPS_24H_WARN NEW_ADMINS_24H_WARN SETTING_CHANGES_24H_WARN MODERATION_24H_WARN DELETIONS_24H_WARN; do
  out=$(env SRC_DB_CONTAINER="$DB" "$var=0" bash ./health-check.sh 2>&1); code=$?
  if [ "$code" = 1 ] && [ "$(grep -c '^WARN' <<<"$out")" = 1 ]; then
    ok "兆候の項目（$var）：しきい値を超えると、その項目だけが、WARN になって、失敗する"
  else
    ng "兆候の項目（$var）が、想定どおりに検出されない（終了コード $code、WARN $(grep -c '^WARN' <<<"$out") 件）"; echo "$out" | grep -E "^(WARN|ERROR)" | head -3
  fi
done

[ "$failed" = 0 ] && echo "監視スクリプトの確認：すべて想定どおり" || { echo "監視スクリプトの確認：想定外があります"; exit 1; }
