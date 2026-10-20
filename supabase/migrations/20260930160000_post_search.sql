-- Issue #16：投稿本文の日本語検索（PGroonga）と、新着順のキーセット・ページング。
--
-- 方式の選定（実測。docs/検索方式の実測.md）：100万行で、稀な1〜2文字の語は pg_trgm が約0.8秒（インデックス不可）、
-- PGroongaは約12ms。日本語は1〜2文字の語が中心のためPGroongaを採用する。
-- ただし、RLSのあるテーブルでは、leakproofでない演算子（&@）をインデックス条件に使えず、public_postsビュー
-- 越しだと20万行で約330msの全件走査になる。そのため、検索はsecurity definerの関数で行い、公開条件を
-- 関数の中に明示する（member_posts・feed_postsと同じ意味。supabase/tests/post_search_test.sqlで一致を検証）。

-- PGroongaはextensionsスキーマに入れる（Supabaseの標準）。インデックスの演算子クラスを引けるよう、
-- この移行の間だけsearch_pathにextensionsを含める。
set local search_path = public, extensions;

-- PGroongaが使える環境（Supabase）でだけ、拡張とインデックスを作る。使えない環境（RDSなど）では、
-- 検索は索引なしの代替になる（AWS移行の段階5で、pg_bigmの索引に置き換える。docs/AWS移行設計案.md）。
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pgroonga') then
    create extension if not exists pgroonga with schema extensions;
    create index posts_body_pgroonga on public.posts using pgroonga (body);
  end if;
end
$$;

-- 検索・一覧。未ログイン（auth.uid()がnull）は公開投稿のみ。ログイン済みは、個人の非表示・ブロック・
-- 話題／言葉のミュートを適用する（feed_postsと同じ）。コメントの本文は検索対象に含めない。
-- 利用者の入力（検索語）は、SQLに埋め込まず、パラメータとして渡す。
create or replace function public.search_posts(
  p_query text default null,
  p_post_type text default null,
  p_topic_id smallint default null,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 20
)
returns table (
  id uuid,
  author_id uuid,
  post_type text,
  topic_id smallint,
  body text,
  reaction_mode text,
  comment_acceptance text,
  created_at timestamptz,
  updated_at timestamptz,
  edited_at timestamptz,
  comment_count bigint,
  author_nickname text,
  author_icon_key text,
  author_avatar_path text
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  viewer uuid := auth.uid();
  tokens text[];
  sql text;
  n integer;
  i integer;
  max_rows integer := least(greatest(coalesce(p_limit, 20), 1), 50);
  use_pgroonga boolean := exists (select 1 from pg_extension where extname = 'pgroonga');
begin
  if p_post_type is not null and p_post_type not in ('guchi', 'soudan', 'kotsu') then
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
  end if;
  -- ページングのカーソルは、日時とIDの両方が揃っているときだけ使う。
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
  end if;

  -- 検索語：空白（全角を含む）で区切って最大5語、全体で100文字まで。全ての語を含む投稿を探す（AND）。
  if char_length(coalesce(p_query, '')) > 100 then
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
  end if;
  tokens := array(
    select t from regexp_split_to_table(btrim(coalesce(p_query, '')), '[\s　]+') as t where t <> ''
  );
  n := coalesce(array_length(tokens, 1), 0);
  if n > 5 then
    raise exception 'VALIDATION_FAILED' using errcode = 'P0001';
  end if;

  -- SQLの文字列に入るのは、固定の断片だけ（利用者の入力は$1〜$11のパラメータ）。
  sql := $q$
    select
      p.id,
      case when $5 is not null then p.author_id end,
      p.post_type, p.topic_id, p.body, p.reaction_mode, p.comment_acceptance,
      p.created_at, p.updated_at, p.edited_at,
      public.post_comment_count(p.id),
      pr.nickname, pr.icon_key, pr.avatar_path
    from public.posts p
    left join public.profiles pr on pr.id = p.author_id
    where p.hidden_at is null
      and ($1 is null or p.post_type = $1)
      and ($2 is null or p.topic_id = $2)
      and ($3 is null or (p.created_at, p.id) < ($3, $4))
  $q$;

  for i in 1..n loop
    if use_pgroonga then
      sql := sql || format(' and p.body operator(extensions.&@) $%s', 5 + i);
    else
      -- 代替（索引なし）：NFKC正規化・大文字小文字を無視した部分一致。PGroongaの&@と同じ意味に揃える。
      sql := sql || format(' and position(lower(normalize($%s, nfkc)) in lower(normalize(p.body, nfkc))) > 0', 5 + i);
    end if;
  end loop;

  if viewer is not null then
    sql := sql || $q$
      and not exists (
        select 1 from public.hidden_items h
        where h.user_id = $5 and h.target_type = 'post' and h.target_id = p.id)
      and not exists (
        select 1 from public.blocks b
        where b.blocker_id = $5 and b.blocked_id = p.author_id)
      and (p.topic_id is null or not exists (
        select 1 from public.muted_topics t
        where t.user_id = $5 and t.topic_id = p.topic_id))
      and not exists (
        select 1 from public.muted_words w
        where w.user_id = $5
          and position(w.normalized_word in lower(normalize(p.body, nfkc))) > 0)
    $q$;
  end if;

  sql := sql || ' order by p.created_at desc, p.id desc limit $11';

  return query execute sql
    using p_post_type, p_topic_id, p_before_created_at, p_before_id, viewer,
      tokens[1], tokens[2], tokens[3], tokens[4], tokens[5], max_rows;
end;
$$;

comment on function public.search_posts(text, text, smallint, timestamptz, uuid, integer) is
  '投稿本文の日本語検索と新着順のキーセット・ページング。security definerで、公開条件を関数の中に明示している。';

-- 検索は未ログインでも使える（決定済み）。
revoke all on function public.search_posts(text, text, smallint, timestamptz, uuid, integer)
  from public, anon, authenticated;
grant execute on function public.search_posts(text, text, smallint, timestamptz, uuid, integer)
  to anon, authenticated, service_role;
