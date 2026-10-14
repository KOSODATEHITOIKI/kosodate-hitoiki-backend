#!/usr/bin/env bash
# 同時実行の競合テスト。pgTAPは1セッションのため、2本のpsqlを並行して競合させて検証する。
# 前提：`supabase start`済みで、ローカルDBのコンテナが起動していること。
#   npm run supabase:start && npm run test:concurrency
set -uo pipefail

CONTAINER="${DB_CONTAINER:-supabase_db_kosodate-hitoiki-backend}"
FAILED=0

psql_run() { docker exec -i "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -q -t -A "$@"; }

check() { # check <説明> <期待値> <実測値>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1（期待: $2 / 実測: $3）"
    FAILED=1
  fi
}

uuid() { printf '00000000-0000-0000-0000-%012x' "$1"; }

# ---------------------------------------------------------------------------
# 1. 通報：既存1件＋別の2人が同時に通報 → 3人到達で必ず自動非表示になる
# ---------------------------------------------------------------------------
U1=$(uuid 0xb1); U2=$(uuid 0xb2); U3=$(uuid 0xb3); U4=$(uuid 0xb4); POST=$(uuid 0xe1)
psql_run <<SQL
insert into auth.users (id) values ('$U1'),('$U2'),('$U3'),('$U4') on conflict do nothing;
insert into public.posts (id, author_id, post_type, body) values ('$POST','$U1','guchi','race') on conflict do nothing;
update public.posts set hidden_at = null where id = '$POST';
delete from public.reports where target_id = '$POST';
insert into public.reports (reporter_id, target_type, target_id, reason) values ('$U2','post','$POST','other');
SQL

( psql_run <<SQL
begin;
insert into public.reports (reporter_id, target_type, target_id, reason) values ('$U3','post','$POST','other');
select pg_sleep(3);
commit;
SQL
) >/dev/null &
sleep 1
psql_run <<SQL >/dev/null
begin;
insert into public.reports (reporter_id, target_type, target_id, reason) values ('$U4','post','$POST','other');
commit;
SQL
wait

check "同時通報で3人到達を取りこぼさない（未対応の通報者数）" "3" \
  "$(psql_run -c "select count(distinct reporter_id) from public.reports where target_id='$POST' and resolved_at is null")"
check "同時通報で3人到達したら自動一時非表示になる" "t" \
  "$(psql_run -c "select hidden_at is not null from public.posts where id='$POST'")"

psql_run <<SQL
delete from public.reports where target_id = '$POST';
delete from public.posts where id = '$POST';
delete from auth.users where id in ('$U1','$U2','$U3','$U4');
SQL

# ---------------------------------------------------------------------------
# 2. ニックネーム：Aが旧名を手放すのと同時にBがその名前を登録 → Bは予約で拒否される
# ---------------------------------------------------------------------------
A=$(uuid 0xc1); B=$(uuid 0xc2)
psql_run <<SQL
delete from public.profiles where id in ('$A','$B');
delete from public.nickname_reservations where normalized_nickname in ('racex','racey');
insert into auth.users (id) values ('$A'),('$B') on conflict do nothing;
insert into public.profiles (id, nickname) values ('$A','RaceX');
-- 30日の変更制限を満たすため、Aの最終変更日を過去にする（nickname列を更新しないためトリガーは動かない）。
update public.profiles set nickname_changed_at = now() - interval '31 days' where id = '$A';
SQL

( psql_run <<SQL >/dev/null
begin;
update public.profiles set nickname = 'RaceY' where id = '$A';
select pg_sleep(3);
commit;
SQL
) &
sleep 1
B_OUT=$(psql_run <<SQL 2>&1
begin;
insert into public.profiles (id, nickname) values ('$B','racex');
commit;
SQL
)
wait

check "旧名を手放すのと同時の登録は、予約により拒否される" "0" \
  "$(psql_run -c "select count(*) from public.profiles where id='$B'")"
case "$B_OUT" in
  *"この名前は現在使用できません"*) echo "ok   - 拒否理由は旧名の予約" ;;
  *) echo "FAIL - 拒否理由が想定と異なる: $B_OUT"; FAILED=1 ;;
esac
check "旧名はAのために予約されている" "racex" \
  "$(psql_run -c "select normalized_nickname from public.nickname_reservations where previous_owner_id='$A'")"

psql_run <<SQL
delete from public.profiles where id in ('$A','$B');
delete from public.nickname_reservations where normalized_nickname in ('racex','racey');
delete from auth.users where id in ('$A','$B');
SQL

# ---------------------------------------------------------------------------
# 3. ニックネーム：同じ名前を2人が同時に新規登録 → 片方だけ成功する
# ---------------------------------------------------------------------------
C=$(uuid 0xc3); D=$(uuid 0xc4)
psql_run <<SQL
delete from public.profiles where id in ('$C','$D');
insert into auth.users (id) values ('$C'),('$D') on conflict do nothing;
SQL

( psql_run <<SQL >/dev/null 2>&1
begin;
insert into public.profiles (id, nickname) values ('$C','Same');
select pg_sleep(2);
commit;
SQL
) &
sleep 1
psql_run <<SQL >/dev/null 2>&1
begin;
insert into public.profiles (id, nickname) values ('$D','ｓａｍｅ');
commit;
SQL
wait

check "同名の同時新規登録は1人だけ成功する" "1" \
  "$(psql_run -c "select count(*) from public.profiles where id in ('$C','$D')")"

psql_run <<SQL
delete from public.profiles where id in ('$C','$D');
delete from auth.users where id in ('$C','$D');
SQL

# ---------------------------------------------------------------------------
# 4. コメント：受付終了とコメント保存が同時に走っても、受付終了後に新規コメントが保存されない
# ---------------------------------------------------------------------------
E1=$(uuid 0xd1); E2=$(uuid 0xd2); EPOST=$(uuid 0xe2)
psql_run <<SQL
delete from public.posts where id = '$EPOST';
delete from public.profiles where id in ('$E1','$E2');
insert into auth.users (id) values ('$E1'),('$E2') on conflict do nothing;
insert into public.profiles (id, nickname) values ('$E1','RaceOwner'),('$E2','RaceCommenter');
insert into public.posts (id, author_id, post_type, body, reaction_mode, comment_acceptance)
  values ('$EPOST','$E1','soudan','race','want_comments','open');
SQL

# セッションA：受付を終了し、コミットを3秒遅らせる（その間、投稿行を排他ロックしている）
( psql_run <<SQL >/dev/null
begin;
select public.set_post_reaction_mode('$E1', '$EPOST', 'want_comments', 'closed');
select pg_sleep(3);
commit;
SQL
) &
sleep 1
# セッションB：Aが未コミットの間にコメントを保存しようとする。Aの確定を待ち、受付終了で拒否されるはず。
C_OUT=$(psql_run <<SQL 2>&1
select public.create_comment('$E2', '$EPOST', null, '遅れたコメント', null);
SQL
)
wait

check "受付終了と同時のコメントは保存されない" "0" \
  "$(psql_run -c "select count(*) from public.comments where post_id='$EPOST'")"
case "$C_OUT" in
  *COMMENTS_CLOSED*) echo "ok   - 拒否理由は受付終了（COMMENTS_CLOSED）" ;;
  *) echo "FAIL - 拒否理由が想定と異なる: $C_OUT"; FAILED=1 ;;
esac

# 逆順：コメント保存が先に確定していれば、後から受付を終了してもコメントは残る
psql_run <<SQL >/dev/null
update public.posts set comment_acceptance = 'open' where id = '$EPOST';
SQL
( psql_run <<SQL >/dev/null
begin;
select public.create_comment('$E2', '$EPOST', null, '先に保存', null);
select pg_sleep(3);
commit;
SQL
) &
sleep 1
psql_run <<SQL >/dev/null
select public.set_post_reaction_mode('$E1', '$EPOST', 'want_comments', 'closed');
SQL
wait
check "先に確定したコメントは、受付終了後も残る" "1" \
  "$(psql_run -c "select count(*) from public.comments where post_id='$EPOST'")"

psql_run <<SQL
delete from public.posts where id = '$EPOST';
delete from public.profiles where id in ('$E1','$E2');
delete from auth.users where id in ('$E1','$E2');
SQL

# ---------------------------------------------------------------------------
# 5. 共感：同じ人が同じ投稿に別々の定型文を同時に選んでも、1件に保たれる（1投稿1人1つ）
# ---------------------------------------------------------------------------
G1=$(uuid 0xf1); G2=$(uuid 0xf2); GPOST=$(uuid 0xe3)
psql_run <<SQL
delete from public.posts where id = '$GPOST';
delete from public.profiles where id in ('$G1','$G2');
insert into auth.users (id) values ('$G1'),('$G2') on conflict do nothing;
insert into public.profiles (id, nickname) values ('$G1','RxOwner'),('$G2','RxFan');
insert into public.reaction_types (id, label, is_active) overriding system value
  values (91,'race-a',true),(92,'race-b',true) on conflict do nothing;
insert into public.posts (id, author_id, post_type, body) values ('$GPOST','$G1','guchi','race');
SQL

( psql_run <<SQL >/dev/null
begin;
select public.set_reaction('$G2', '$GPOST', 91::smallint);
select pg_sleep(3);
commit;
SQL
) &
sleep 1
psql_run <<SQL >/dev/null
select public.set_reaction('$G2', '$GPOST', 92::smallint);
SQL
wait

check "同時に選んでも、共感は1件のまま" "1" \
  "$(psql_run -c "select count(*) from public.reactions where post_id='$GPOST' and user_id='$G2'")"
check "あとから確定した選択が残る（選び直し）" "92" \
  "$(psql_run -c "select reaction_type_id from public.reactions where post_id='$GPOST' and user_id='$G2'")"

# 共感の登録中に、投稿者がブロックしても、ブロック後の新規登録は拒否される
psql_run <<SQL >/dev/null
delete from public.reactions where post_id = '$GPOST';
insert into public.blocks (blocker_id, blocked_id) values ('$G1','$G2');
SQL
B_OUT=$(psql_run <<SQL 2>&1
select public.set_reaction('$G2', '$GPOST', 91::smallint);
SQL
)
case "$B_OUT" in
  *BLOCKED*) echo "ok   - ブロック後の共感は拒否される（BLOCKED）" ;;
  *) echo "FAIL - ブロック後の共感が拒否されない: $B_OUT"; FAILED=1 ;;
esac

psql_run <<SQL
delete from public.posts where id = '$GPOST';
delete from public.reaction_types where id in (91,92);
delete from public.profiles where id in ('$G1','$G2');
delete from auth.users where id in ('$G1','$G2');
SQL

exit "$FAILED"
