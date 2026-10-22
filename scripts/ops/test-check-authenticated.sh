#!/usr/bin/env bash
# check-authenticated.mjs（ログイン済みの視点での公開範囲の確認）が、空回りしていないことを確かめる。
#   ①正しい設定では、すべて成功する（終了コード0）
#   ②わざと穴を開けると（内部用の表を読める・テーブルへ直接書ける）、失敗として検出する（終了コード1）
#   ③穴を元に戻すと、また成功する
# ローカルのSupabaseだけで使う（使い捨てのテスト用アカウントを2つ作り、最後に消す）。要 supabase start。
set -uo pipefail
cd "$(dirname "$0")/../.."

eval "$(npx supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY|SERVICE_ROLE_KEY)=')"
: "${API_URL:?supabase start をしてください}"
case "$API_URL" in
  http://127.0.0.1:*|http://localhost:*) ;;
  *) echo "ローカルのSupabase以外には使いません（穴を開けるテストのため）" >&2; exit 2 ;;
esac

DB="${DB_CONTAINER:-supabase_db_kosodate-hitoiki-backend}"
PSQL="docker exec $DB psql -U postgres -q"
PW="Local-test-$RANDOM$RANDOM-pw"
EA="authchk-a-$RANDOM$RANDOM@example.com"
EB="authchk-b-$RANDOM$RANDOM@example.com"

mk() { # mk <メール>：確認済みのアカウントを作り、IDを出力する
  curl -s -X POST "$API_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$1\",\"password\":\"$PW\",\"email_confirm\":true}" |
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).id||""))'
}
rm_user() { curl -s -o /dev/null -X DELETE "$API_URL/auth/v1/admin/users/$1" -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY"; }

IDA=$(mk "$EA"); IDB=$(mk "$EB")
if [ -z "$IDA" ] || [ -z "$IDB" ]; then echo "FAIL - テスト用アカウントを作れない" >&2; exit 1; fi

restore() { # 開けた穴を、必ず元に戻す
  $PSQL -c "alter table public.idempotency_keys enable row level security; revoke select on public.idempotency_keys from authenticated; delete from public.idempotency_keys where key = 'leak-test';" \
        -c "drop policy if exists tmp_leak_topics on public.topics; revoke insert on public.topics from authenticated; delete from public.topics where label = 'ちょくせつ';" \
        -c "alter table public.profile_icons enable row level security; revoke select on public.profile_icons from authenticated;" >/dev/null 2>&1
}
cleanup() { restore; rm_user "$IDA"; rm_user "$IDB"; }
trap cleanup EXIT

$PSQL -c "insert into public.profiles (id, nickname, created_at) values ('$IDA', 'えー$RANDOM', now() - interval '3 days'), ('$IDB', 'びー$RANDOM', now() - interval '3 days')" || exit 1

run() { API_URL="$API_URL" ANON_KEY="$ANON_KEY" EMAIL_A="$EA" PASSWORD_A="$PW" EMAIL_B="$EB" PASSWORD_B="$PW" node scripts/ops/check-authenticated.mjs; }
failed=0
ok() { echo "ok   - $1"; }
ng() { echo "FAIL - $1"; failed=1; }

out=$(run 2>&1); code=$?
if [ "$code" = 0 ] && grep -q "すべて想定どおり" <<<"$out" && ! grep -q "^FAIL" <<<"$out"; then
  ok "正しい設定では、すべて成功する"
else
  ng "正しい設定なのに、失敗した（終了コード $code）"; echo "$out" | grep -E "^FAIL" | head -5
fi

$PSQL -c "insert into public.idempotency_keys (user_id, endpoint, key) values ('$IDB', 'post.create', 'leak-test'); alter table public.idempotency_keys disable row level security; grant select on public.idempotency_keys to authenticated;" \
      -c "create policy tmp_leak_topics on public.topics for insert to authenticated with check (true); grant insert on public.topics to authenticated;" \
      -c "grant select on public.profile_icons to authenticated; alter table public.profile_icons disable row level security;" || exit 1
out=$(run 2>&1); code=$?
if [ "$code" = 1 ] && grep -q "^FAIL - idempotency_keys" <<<"$out" && grep -q "^FAIL - topics へ直接書き込めた" <<<"$out" && grep -q "^FAIL - profile_icons" <<<"$out"; then
  ok "わざと穴を開けると、3つとも検出して、失敗する"
else
  ng "開けた穴を、検出できなかった（終了コード $code）"; echo "$out" | grep -E "^FAIL" | head -5
fi

restore
out=$(run 2>&1); code=$?
if [ "$code" = 0 ] && ! grep -q "^FAIL" <<<"$out"; then
  ok "穴を元に戻すと、また成功する"
else
  ng "元に戻したのに、失敗した（終了コード $code）"; echo "$out" | grep -E "^FAIL" | head -5
fi

# ログインに失敗したときは、原因（Authのエラーコード）を出し、パスワード・メールアドレスは出さない
out=$(API_URL="$API_URL" ANON_KEY="$ANON_KEY" EMAIL_A="$EA" PASSWORD_A="$PW" EMAIL_B="$EB" PASSWORD_B="wrong-$PW" node scripts/ops/check-authenticated.mjs 2>&1); code=$?
if [ "$code" = 1 ] && grep -q "^FAIL - アカウントBでログインできない（HTTP 400、invalid_credentials）" <<<"$out"    && grep -q "Bにログインできなかったので" <<<"$out" && ! grep -qF "$PW" <<<"$out" && ! grep -qF "$EB" <<<"$out"; then
  ok "ログインに失敗したら、原因を示して失敗する（パスワード・メールアドレスは出さない）"
else
  ng "ログイン失敗の表示が想定外（終了コード $code）"; echo "$out" | grep -E "^(FAIL|info)" | head -3
fi

[ "$failed" = 0 ] && echo "ログイン済みの確認スクリプトの検証：すべて想定どおり" || { echo "ログイン済みの確認スクリプトの検証：想定外があります"; exit 1; }
