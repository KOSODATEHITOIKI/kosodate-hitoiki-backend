#!/usr/bin/env bash
# Edge Functionsの配線の結合テスト。ローカルのSupabaseへ実際に接続する（OpenAIはフェイク）。
# 前提：`supabase start`済み。
#   npm run supabase:start && npm run test:functions-integration
set -euo pipefail

cd "$(dirname "$0")/../../.."

# `supabase status -o env` の出力から接続情報を取り込む（値はログに出さない）。
eval "$(npx supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY|SERVICE_ROLE_KEY)=')"
export SUPABASE_URL="$API_URL"
export SUPABASE_ANON_KEY="$ANON_KEY"
export SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY"

cd supabase/functions
npx deno test --frozen --allow-env --allow-net _shared/profile/wiring.integration.ts
