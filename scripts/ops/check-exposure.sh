#!/usr/bin/env bash
# 実際のAPIに、未ログイン（anon）の鍵だけで問い合わせて、公開範囲が想定どおりか確かめる。
# コードやDBテストではなく、**動いている環境（local・dev・prod）に対して**確かめる。
# 設定の差分（dev と prod の違い、ダッシュボードの設定ミス）による意図しない公開を見つけるため。
#
#   API_URL=https://<project>.supabase.co ANON_KEY=<公開キー（anon/publishable）> bash scripts/ops/check-exposure.sh
#
# ANON_KEY は公開してよい鍵（アプリにも入る）。service_role・secret の鍵は、絶対に使わない。
# 確認すること：①未ログインから見えるテーブル・ビュー・関数 ②機密テーブルの読み取り ③内部の関数の呼び出し
#   ④画像の一覧 ⑤GraphQL ⑥Edge Functions（内部用・運営用が存在を明かさないか） ⑦認証の設定
# いずれか1つでも想定外なら、失敗（終了コード1）にする。
set -uo pipefail

: "${API_URL:?API_URL を指定してください}"
: "${ANON_KEY:?ANON_KEY（公開キー）を指定してください}"
API_URL="${API_URL%/}"
FAILED=0
ok() { echo "ok   - $1"; }
ng() { echo "FAIL - $1"; FAILED=1; }
warn() { echo "WARN - $1"; }
code() { curl -s -o /dev/null -w "%{http_code}" -m 30 "$@"; }
H=(-H "apikey: $ANON_KEY")

# 鍵が service_role の可能性を検出して、使わせない（誤って特権キーを渡した場合に、検査が無意味になるため）
payload=$(echo "$ANON_KEY" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null || true)
if echo "$payload" | grep -q '"role":"service_role"'; then
  echo "ANON_KEY が service_role の鍵です。公開キー（anon）を使ってください。" >&2
  exit 2
fi

echo "== 1. 未ログインから見えるテーブル・ビュー・関数（OpenAPI）=="
# posts は、投稿者IDなどを除いた列だけを未ログインに許可している（列単位の権限）。下の「列」の確認で、読めない列を確かめる。
ALLOWED_PATHS="/ /posts /public_posts /reaction_types /topics /rpc/post_author_profile /rpc/post_comment_count /rpc/search_posts"
paths=$(curl -s -m 30 "${H[@]}" "$API_URL/rest/v1/" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    try{console.log(Object.keys(JSON.parse(s).paths||{}).join(" "))}catch{console.log("__PARSE_ERROR__")}})')
if [ "$paths" = "__PARSE_ERROR__" ] || [ -z "$paths" ]; then
  warn "OpenAPI を読めませんでした（無効化されている可能性）。個別の確認（2・3）で補います"
else
  unexpected=""
  for p in $paths; do
    case " $ALLOWED_PATHS " in *" $p "*) ;; *) unexpected="$unexpected $p" ;; esac
  done
  if [ -z "$unexpected" ]; then ok "未ログインから見えるのは、公開マスタ・公開ビュー・公開の関数だけ"; else ng "想定外の公開:$unexpected"; fi
fi

echo "== 2. 機密テーブル・ビュー・列を、未ログインで読めないこと =="
before=$FAILED
SENSITIVE="profiles comments reactions saved_posts hidden_items blocks muted_topics muted_words notifications notification_settings push_devices push_deliveries reports moderation_actions account_restrictions admin_users admin_report_queue app_settings app_settings_history nickname_reservations terms_acceptances idempotency_keys write_events request_budget pending_storage_deletions deletion_ledger public_profiles member_posts feed_posts member_comments my_posts saved_post_list"
for t in $SENSITIVE; do
  c=$(code "${H[@]}" "$API_URL/rest/v1/$t?limit=1")
  case "$c" in 401|403|404) ;; *) ng "$t が未ログインで応答した（HTTP $c）" ;; esac
done
# 列単位の確認：公開してよい列は読め、投稿者ID・個人に結び付く列は読めない
c=$(code "${H[@]}" "$API_URL/rest/v1/posts?select=id,body&limit=1")
[ "$c" = "200" ] && ok "posts の公開列（id, body）は読める" || ng "posts の公開列が読めない（HTTP $c）"
for col in author_id hidden_at; do
  [ "$col" = "hidden_at" ] && continue
  c=$(code "${H[@]}" "$API_URL/rest/v1/posts?select=$col&limit=1")
  case "$c" in 401|403) ;; *) ng "posts.$col が未ログインで読める（HTTP $c）" ;; esac
done
c=$(code "${H[@]}" "$API_URL/rest/v1/public_profiles?select=bio&limit=1")
case "$c" in 401|403|404|400) ;; *) ng "本文（bio）が未ログインで読める（HTTP $c）" ;; esac
[ "$FAILED" = "$before" ] && ok "機密テーブル・ビューは、すべて拒否された"

echo "== 3. 内部・書き込み用の関数を、未ログインで呼べないこと =="
before=$FAILED
for fn in create_post create_comment create_report set_reaction remove_reaction withdraw_account replay_deletion_ledger import_deletion_ledger purge_expired_records claim_push_deliveries finish_push_delivery set_app_setting preflight_write moderation_apply create_profile register_push_device session_started_at generate_reaction_digests claim_storage_deletions; do
  c=$(code -X POST "${H[@]}" -H "Content-Type: application/json" -d '{}' "$API_URL/rest/v1/rpc/$fn")
  case "$c" in 401|403|404) ;; *) ng "関数 $fn が未ログインで応答した（HTTP $c）" ;; esac
done
[ "$FAILED" = "$before" ] && ok "内部の関数は、すべて拒否された"

echo "== 4. 画像（avatars）の一覧を、未ログインで取れないこと =="
list=$(curl -s -m 30 -X POST "${H[@]}" -H "Content-Type: application/json" -d '{"prefix":"","limit":5}' "$API_URL/storage/v1/object/list/avatars")
if echo "$list" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.exit(Array.isArray(j)&&j.length>0?1:0)}catch{process.exit(0)}})'; then
  ok "画像の一覧は取れない（URLを知っている画像だけが見える）"
else
  ng "avatars の一覧が未ログインで取れた"
fi

echo "== 5. GraphQL =="
gq=$(curl -s -m 30 -X POST "${H[@]}" -H "Content-Type: application/json" -d '{"query":"{ __schema { types { name } } }"}' "$API_URL/graphql/v1")
if echo "$gq" | grep -q "not enabled"; then
  ok "GraphQL（pg_graphql）は無効"
else
  if echo "$gq" | grep -Eqi '"(Profile|Report|ModerationAction|AdminUser|Notification|PushDevice|AppSetting)[a-zA-Z]*"'; then
    ng "GraphQL の型に機密テーブルが見える"
  else
    warn "GraphQL が有効です。公開範囲は REST と同じ権限に従いますが、使わないなら無効にしてください"
  fi
fi

echo "== 6. Edge Functions：内部用・運営用が存在を明かさないこと =="
if [ "${SKIP_FUNCTIONS:-}" = "1" ]; then warn "Edge Functions の確認を飛ばしました（SKIP_FUNCTIONS=1。クラウドでは必ず確認する）"; else
fn() { # fn <メソッド> <パス> <期待するHTTP（|区切り）>
  c=$(code -X "$1" "${H[@]}" -H "Authorization: Bearer $ANON_KEY" -H "Content-Type: application/json" -d '{}' "$API_URL/functions/v1/$2")
  case "|$3|" in *"|$c|"*) ok "$2 → HTTP $c" ;; *) ng "$2 が想定外の応答（HTTP $c、期待 $3）" ;; esac
}
fn POST posts 401
fn POST comments 401
fn POST reports 401
fn POST profile-create 401
fn POST account-delete 401
fn GET moderation/settings 401
fn POST moderation/actions 401
fn POST push-dispatch 404
fn POST storage-cleanup 404
fi

echo "== 7. 認証の設定 =="
settings=$(curl -s -m 30 "${H[@]}" "$API_URL/auth/v1/settings")
echo "$settings" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    try{const j=JSON.parse(s);
      console.log("info - メールの自動確認（mailer_autoconfirm）: "+j.mailer_autoconfirm+" / 新規登録の停止（disable_signup）: "+j.disable_signup);
      process.exit(j.mailer_autoconfirm===true?3:0)}catch{console.log("info - 認証の設定を読めませんでした");process.exit(0)}})'
if [ $? -eq 3 ]; then
  if [ "${EXPECT_EMAIL_CONFIRM:-}" = "1" ]; then ng "メールの確認が無効（mailer_autoconfirm=true）。本番では確認を必須にする"; else warn "メールの確認が無効です（ローカル・devなら想定内。本番では EXPECT_EMAIL_CONFIRM=1 で検査します）"; fi
fi

echo
[ "$FAILED" = 0 ] && echo "公開範囲の確認：すべて想定どおり" || { echo "公開範囲の確認：想定外があります"; exit 1; }
