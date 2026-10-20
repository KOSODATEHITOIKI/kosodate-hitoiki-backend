#!/usr/bin/env bash
# バックアップ → 削除 → 復元 → 台帳で再削除、を、ローカルのSupabaseで通しで確かめる。
# 「削除済みのデータが、バックアップからの復元で再公開されない」ことの検証。
#
#   npm run supabase:start && bash scripts/ops/verify-local.sh
#
# 注意：ローカルのDBのデータを置き換える（復元するため）。ローカル専用。クラウドには向けない。
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

export SRC_DB_CONTAINER="${DB_CONTAINER:-supabase_db_kosodate-hitoiki-backend}"
export DST_DB_CONTAINER="$SRC_DB_CONTAINER"
unset SRC_DATABASE_URL DST_DATABASE_URL

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
check() { # check <説明> <期待値> <実測値>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1（期待: $2 / 実測: $3）"; FAILED=1; fi
}
q() { db_psql SRC -c "$1"; }
# テスト用のユーザーを片付ける（通知などの参照があるため、直接deleteせず、退会の処理を使う）
cleanup_users() {
  for u in "$A" "$B"; do q "select public.withdraw_account('$u')" >/dev/null; done
  q "delete from public.nickname_reservations where previous_owner_id in ('$A','$B')" >/dev/null
  q "delete from public.deletion_ledger where target_id in ('$A','$B','$P1','$P2','$P3','$C1','$C2')" >/dev/null
}

A='ffff0000-0000-0000-0000-00000000000a' # バックアップ後に退会する人
B='ffff0000-0000-0000-0000-00000000000b' # 残る人
P1='ffff0000-0000-0000-0000-0000000000a1' # Aの投稿
P2='ffff0000-0000-0000-0000-0000000000b2' # バックアップ後にBが削除する投稿
P3='ffff0000-0000-0000-0000-0000000000b3' # 残る投稿
C1='ffff0000-0000-0000-0000-0000000000c1' # バックアップ後にBが削除するコメント（P3へ）
C2='ffff0000-0000-0000-0000-0000000000c2' # 残るコメント

echo "== 準備：テスト用のデータを作る =="
cleanup_users
q "insert into auth.users (id) values ('$A'), ('$B');
   insert into public.profiles (id, nickname) values ('$A', 'ふっかつたいかい'), ('$B', 'ふっかつのこる');
   insert into public.notification_settings (user_id) values ('$A'), ('$B');
   insert into public.posts (id, author_id, post_type, body, reaction_mode, comment_acceptance) values
     ('$P1', '$A', 'guchi', 'Aの投稿', 'quiet_support', null),
     ('$P2', '$B', 'guchi', 'Bの消す投稿', 'quiet_support', null),
     ('$P3', '$B', 'soudan', 'Bの残る投稿', 'want_comments', 'open');
   insert into public.comments (id, post_id, author_id, body) values
     ('$C1', '$P3', '$B', '消すコメント'), ('$C2', '$P3', '$A', 'Aのコメント');" >/dev/null

echo "== 1. バックアップを取り、使い捨て環境への復元で件数を検証する =="
OUT="$WORK/backup" bash ./backup.sh 2>/dev/null
bash ./verify-backup.sh "$WORK/backup" 2>/dev/null && echo "ok   - バックアップが復元でき、件数が一致する" || { echo "FAIL - 復元の検証に失敗"; FAILED=1; }

echo "== 2. バックアップのあとに、削除と退会が起きる =="
# 復元の検証でデータが入れ替わるため、バックアップ時点の状態を復元してから、削除と退会を起こす
bash ./restore.sh "$WORK/backup/dump.pgdump" >/dev/null 2>&1
check "復元後、Aが存在する（バックアップ時点）" "1" "$(q "select count(*) from auth.users where id='$A'")"
q "select public.withdraw_account('$A')" >/dev/null
q "delete from public.posts where id = '$P2'" >/dev/null
q "update public.comments set deleted_at = now() where id = '$C1'" >/dev/null
check "退会したAは存在しない" "0" "$(q "select count(*) from auth.users where id='$A'")"
check "削除した投稿P2は存在しない" "0" "$(q "select count(*) from public.posts where id='$P2'")"

echo "== 3. 台帳を書き出す（バックアップの取得後の削除を、別の場所へ保管する）=="
OUT="$WORK/ledger.json" bash ./ledger-export.sh 2>/dev/null
for id in $A $P1 $P2 $C1; do
  grep -q "$id" "$WORK/ledger.json" && echo "ok   - 台帳に記録されている: $id" || { echo "FAIL - 台帳にない: $id"; FAILED=1; }
done

echo "== 4. 古いバックアップを台帳なしで復元すると、削除したデータが復活する（問題の再現）=="
bash ./restore.sh "$WORK/backup/dump.pgdump" >/dev/null 2>&1
check "復活：退会したAが戻っている" "1" "$(q "select count(*) from auth.users where id='$A'")"
check "復活：削除した投稿P2が戻っている" "1" "$(q "select count(*) from public.posts where id='$P2'")"
check "復活：削除したコメントC1の本文が戻っている" "消すコメント" "$(q "select body from public.comments where id='$C1'")"

echo "== 5. 台帳を取り込んで再削除すると、復活しない =="
bash ./restore.sh "$WORK/backup/dump.pgdump" "$WORK/ledger.json" >/dev/null 2>&1
check "退会したAは復活しない" "0" "$(q "select count(*) from auth.users where id='$A'")"
check "退会したAのプロフィールは復活しない" "0" "$(q "select count(*) from public.profiles where id='$A'")"
check "退会したAの投稿P1は復活しない" "0" "$(q "select count(*) from public.posts where id='$P1'")"
check "削除した投稿P2は復活しない" "0" "$(q "select count(*) from public.posts where id='$P2'")"
check "削除したコメントC1の本文は復活しない" "" "$(q "select coalesce(body,'') from public.comments where id='$C1'")"
check "削除したコメントC1は削除済みに戻る" "t" "$(q "select deleted_at is not null from public.comments where id='$C1'")"
check "Aが書いたコメントC2は復活しない" "0" "$(q "select count(*) from public.comments where id='$C2'")"
echo "-- 残るものは残る"
check "残る人Bは残る" "1" "$(q "select count(*) from auth.users where id='$B'")"
check "残る投稿P3は残る" "1" "$(q "select count(*) from public.posts where id='$P3'")"

echo "== 後始末 =="
cleanup_users

[ "$FAILED" = 0 ] && echo "すべて成功" || { echo "失敗があります"; exit 1; }
