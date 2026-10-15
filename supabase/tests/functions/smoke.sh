#!/usr/bin/env bash
# Edge Runtime上で全Functionのコードが読み込めることの確認（配備時のビルドエラーを事前に検出する）。
# ログインしていないトークンで呼び、各Functionが自分のJSONエラー（error.code）を返せばOK。
# 読み込み（import解決）に失敗すると、エラーコードのないレスポンスになる。
#   npm run supabase:start && npm run test:functions-smoke
set -uo pipefail
cd "$(dirname "$0")/../../.."

eval "$(npx supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY)=')"
LOG="$(mktemp)"
npx supabase functions serve >"$LOG" 2>&1 &
SERVE_PID=$!
trap 'kill $SERVE_PID 2>/dev/null; pkill -f "supabase functions serve" 2>/dev/null; rm -f "$LOG"' EXIT

FAILED=0
# 関数名:メソッド:期待するerror.code
CASES=(
  "profile-create:POST:UNAUTHENTICATED"
  "profile-nickname:POST:UNAUTHENTICATED"
  "profile-update:PATCH:UNAUTHENTICATED"
  "profile-avatar:PUT:UNAUTHENTICATED"
  "posts:POST:UNAUTHENTICATED"
  "comments:POST:UNAUTHENTICATED"
  "reports:POST:UNAUTHENTICATED"
  "moderation/actions:POST:UNAUTHENTICATED"
  "push-dispatch:POST:NOT_FOUND"
  "account-delete:POST:UNAUTHENTICATED"
  "storage-cleanup:POST:NOT_FOUND"
)

for c in "${CASES[@]}"; do
  IFS=: read -r fn method expected <<<"$c"
  got=""
  for _ in $(seq 1 30); do # 起動を最大約2.5分待つ
    got=$(curl -s -m 60 -X "$method" "$API_URL/functions/v1/$fn" \
      -H "Authorization: Bearer $ANON_KEY" -H "Content-Type: application/json" -d '{}' \
      | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).error.code)}catch{console.log("")}})')
    [ -n "$got" ] && break
    sleep 5
  done
  if [ "$got" = "$expected" ]; then
    echo "ok   - $fn は読み込めて $expected を返す"
  else
    echo "FAIL - $fn（期待: $expected / 実測: ${got:-応答なし・読み込み失敗}）"
    FAILED=1
  fi
done

[ "$FAILED" = 1 ] && grep -iE "error|bundle|resolve|import" "$LOG" | head -10
exit "$FAILED"
