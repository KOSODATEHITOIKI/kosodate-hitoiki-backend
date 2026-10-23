-- バックアップ・台帳の書き出し・毎日の健康診断が使う、読み取り専用のDBロール（運用手順 4.3）。
-- SupabaseのSQL Editorで、環境ごとに（dev・prod）、パスワードを書き換えて、1回だけ実行する。パスワードをチャットに貼らない。
--
-- BYPASSRLS が要る理由：読み取り専用でも、行ごとの権限（RLS）は、回避できない。RLSのある表は、全部で、
-- 運営専用・内部専用の表（通報・運営の対処・削除待ち・配信・台帳など）と、auth.users などを含む。BYPASSRLS がないと、
--   ・健康診断が、それらを「0件」と読む（異常があっても「正常」と出る）
--   ・pg_dump が「query would be affected by row-level security policy」で失敗する（バックアップが取れない）
-- pg_read_all_data は、読む権限（SELECT）だけで、書く権限は付かない。default_transaction_read_only は、念のための二重の鍵。
create role backup_reader login password '<強いパスワード>' bypassrls;
grant pg_read_all_data to backup_reader;
alter role backup_reader set default_transaction_read_only = on;
