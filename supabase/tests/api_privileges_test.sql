-- API（anon・authenticated）が持つ権限の一覧を固定するテスト。
-- 想定外の公開（新しいテーブル・ビュー・関数の公開し忘れ、権限の付けすぎ）があると落ちる。
-- 権限を意図して変えるときは、移行とこのテストの期待値を同時に更新する（deny-by-default）。

BEGIN;
SELECT plan(8);

-- テーブル・ビュー：ロールごとの権限（テーブル単位）
CREATE TEMP TABLE actual_table_privs AS
SELECT (r.rolname::text || ':' || c.relname::text || ':' || p.priv) AS item
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
CROSS JOIN (VALUES ('anon'), ('authenticated')) AS r(rolname)
CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'),
  ('TRIGGER')) AS p(priv)
WHERE c.relkind IN ('r', 'v', 'm', 'p', 'f')
  AND has_table_privilege(r.rolname, c.oid, p.priv);

SELECT is(
  (SELECT string_agg(item::text, ',' ORDER BY item::text COLLATE "C") FROM actual_table_privs WHERE item LIKE 'anon:%'),
  'anon:public_posts:SELECT,anon:reaction_types:SELECT,anon:topics:SELECT',
  '未ログイン（anon）が持つテーブル単位の権限は、公開マスタと公開ビューのSELECTだけ'
);

SELECT is(
  (SELECT string_agg(item::text, ',' ORDER BY item::text COLLATE "C") FROM actual_table_privs WHERE item LIKE 'authenticated:%'),
  'authenticated:account_restrictions:SELECT,authenticated:admin_users:SELECT,authenticated:app_settings:SELECT,authenticated:blocks:DELETE,authenticated:blocks:INSERT,authenticated:blocks:SELECT,authenticated:comments:SELECT,authenticated:feed_posts:SELECT,authenticated:hidden_items:DELETE,authenticated:hidden_items:INSERT,authenticated:hidden_items:SELECT,authenticated:hidden_items:UPDATE,authenticated:member_comments:SELECT,authenticated:member_posts:SELECT,authenticated:moderation_actions:SELECT,authenticated:muted_topics:DELETE,authenticated:muted_topics:INSERT,authenticated:muted_topics:SELECT,authenticated:muted_topics:UPDATE,authenticated:muted_words:DELETE,authenticated:muted_words:INSERT,authenticated:muted_words:SELECT,authenticated:muted_words:UPDATE,authenticated:nickname_reservations:SELECT,authenticated:notification_settings:DELETE,authenticated:notification_settings:INSERT,authenticated:notification_settings:SELECT,authenticated:notification_settings:UPDATE,authenticated:notifications:SELECT,authenticated:posts:SELECT,authenticated:profiles:SELECT,authenticated:public_posts:SELECT,authenticated:public_profiles:SELECT,authenticated:push_devices:DELETE,authenticated:push_devices:INSERT,authenticated:push_devices:SELECT,authenticated:push_devices:UPDATE,authenticated:reaction_types:SELECT,authenticated:reactions:DELETE,authenticated:reactions:INSERT,authenticated:reactions:SELECT,authenticated:reactions:UPDATE,authenticated:reports:SELECT,authenticated:saved_posts:DELETE,authenticated:saved_posts:INSERT,authenticated:saved_posts:SELECT,authenticated:saved_posts:UPDATE,authenticated:terms_acceptances:SELECT,authenticated:topics:SELECT',
  'ログイン済み（authenticated）のテーブル単位の権限が想定どおり（TRUNCATE・TRIGGER・REFERENCESは持たない）'
);

-- 列単位の権限（テーブル単位では持たず、列だけに付いているもの）
CREATE TEMP TABLE actual_column_privs AS
SELECT (r.rolname::text || ':' || c.relname::text || '.' || a.attname::text || ':' || p.priv) AS item
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
CROSS JOIN (VALUES ('anon'), ('authenticated')) AS r(rolname)
CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('REFERENCES')) AS p(priv)
WHERE c.relkind IN ('r', 'v', 'm', 'p', 'f')
  AND has_column_privilege(r.rolname, c.oid, a.attnum, p.priv)
  AND NOT has_table_privilege(r.rolname, c.oid, p.priv);

SELECT is(
  (SELECT string_agg(item::text, ',' ORDER BY item::text COLLATE "C") FROM actual_column_privs WHERE item LIKE 'anon:%'),
  'anon:posts.body:SELECT,anon:posts.comment_acceptance:SELECT,anon:posts.created_at:SELECT,anon:posts.edited_at:SELECT,anon:posts.hidden_at:SELECT,anon:posts.id:SELECT,anon:posts.post_type:SELECT,anon:posts.reaction_mode:SELECT,anon:posts.topic_id:SELECT,anon:posts.updated_at:SELECT',
  '未ログイン（anon）の列単位の権限は posts の公開列だけ（author_idは含まれない）'
);

SELECT is(
  (SELECT string_agg(item::text, ',' ORDER BY item::text COLLATE "C") FROM actual_column_privs WHERE item LIKE 'authenticated:%'),
  'authenticated:notifications.is_read:UPDATE',
  'ログイン済みの列単位の権限は、通知の既読フラグの更新だけ'
);

-- 関数：anon・authenticated が実行できるもの（PUBLICへの付与も検出する）
CREATE TEMP TABLE actual_function_privs AS
SELECT (r.rolname::text || ':' || p.proname::text) AS item
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
CROSS JOIN (VALUES ('anon'), ('authenticated')) AS r(rolname)
WHERE has_function_privilege(r.rolname, p.oid, 'EXECUTE');

SELECT is(
  (SELECT string_agg(item::text, ',' ORDER BY item::text COLLATE "C") FROM actual_function_privs WHERE item LIKE 'anon:%'),
  'anon:post_author_profile,anon:post_comment_count',
  '未ログイン（anon）が実行できる関数は公開コメント件数だけ'
);

SELECT is(
  (SELECT string_agg(item::text, ',' ORDER BY item::text COLLATE "C") FROM actual_function_privs WHERE item LIKE 'authenticated:%'),
  'authenticated:get_post_reaction_count,authenticated:is_admin,authenticated:is_restricted,authenticated:post_author_profile,authenticated:post_comment_count',
  'ログイン済みが実行できる関数は想定した4つだけ（create_profile・トリガー関数などは実行できない）'
);

-- シーケンス
SELECT is(
  (SELECT count(*)::int FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
    CROSS JOIN (VALUES ('anon'), ('authenticated')) AS r(rolname)
    WHERE c.relkind = 'S'
      AND (has_sequence_privilege(r.rolname, c.oid, 'USAGE')
        OR has_sequence_privilege(r.rolname, c.oid, 'UPDATE'))),
  0,
  'anon・authenticated はシーケンスを使えない'
);

-- 今後作られるオブジェクトが、anon・authenticated へ自動で公開されない
SELECT is(
  (SELECT count(*)::int
    FROM pg_default_acl d
    JOIN pg_namespace n ON n.oid = d.defaclnamespace AND n.nspname = 'public',
    LATERAL aclexplode(d.defaclacl) a
    JOIN pg_roles g ON g.oid = a.grantee AND g.rolname IN ('anon', 'authenticated')
    WHERE pg_get_userbyid(d.defaclrole) = 'postgres'),
  0,
  'postgresが publicスキーマに今後作るオブジェクトは、anon・authenticated へ自動で権限が付かない'
);

SELECT * FROM finish();
ROLLBACK;
