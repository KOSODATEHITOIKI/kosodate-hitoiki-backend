-- Issue #14：自分だけの非表示・ブロック・話題／言葉ミュートを、読み取り側でサーバーが強制する。
--
-- 設定の書き込みは、これまでの方針どおり本人限定のRLSで直接操作する（blocks・hidden_items・
-- muted_topics・muted_words）。ここでは、それらを投稿・コメント・通知の取得に反映する。
-- ブロックされた相手への通知は作らない（そもそも相手が参照できる経路がない）。

-- === 言葉ミュート：正規化と上限 ===
-- 一致は、全角・半角と英字の大文字小文字を区別しない部分一致（NFKC＋小文字化）。
-- 上限（100件・100文字）は濫用防止の暫定値（未決事項。確定後に変更する）。
alter table public.muted_words add column normalized_word text;

update public.muted_words
set normalized_word = lower(normalize(btrim(word), nfkc))
where normalized_word is null;

alter table public.muted_words alter column normalized_word set not null;

alter table public.muted_words
  add constraint muted_words_word_length check (char_length(btrim(word)) between 1 and 100);
alter table public.muted_words
  add constraint muted_words_unique_normalized unique (user_id, normalized_word);

create or replace function public.muted_words_before_write()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.word := btrim(new.word);
  new.normalized_word := lower(normalize(new.word, nfkc));

  if tg_op = 'INSERT' then
    -- 同じ利用者の同時登録で上限を超えないよう、利用者単位で直列化する。
    perform pg_advisory_xact_lock(hashtextextended('muted_words:' || new.user_id::text, 0));
    if (select count(*) from public.muted_words where user_id = new.user_id) >= 100 then
      raise exception 'LIMIT_EXCEEDED' using errcode = '54000';
    end if;
  end if;
  return new;
end;
$$;

create trigger muted_words_before_write
  before insert or update of word on public.muted_words
  for each row execute function public.muted_words_before_write();

-- === 投稿の取得（ログイン済み）===
-- member_posts：投稿の詳細。ブロックした相手の投稿と、自分だけの非表示にした投稿を除く。
--   ログイン済みはブロック・通報のために投稿者の利用者ID（author_id）を取得できる。
--   ミュート（話題・言葉）は、通知からの直接参照などを妨げないよう、ここには適用しない。
create view public.member_posts
  with (security_invoker = true) as
select
  p.id,
  p.author_id,
  p.post_type,
  p.topic_id,
  p.body,
  p.reaction_mode,
  p.comment_acceptance,
  p.created_at,
  p.updated_at,
  p.edited_at,
  public.post_comment_count(p.id) as comment_count,
  pr.nickname as author_nickname,
  pr.icon_key as author_icon_key,
  pr.avatar_path as author_avatar_path
from public.posts p
left join public.public_profiles pr on pr.id = p.author_id
where p.hidden_at is null
  and not exists (
    select 1 from public.hidden_items h
    where h.user_id = auth.uid() and h.target_type = 'post' and h.target_id = p.id
  )
  and not exists (
    select 1 from public.blocks b
    where b.blocker_id = auth.uid() and b.blocked_id = p.author_id
  );

comment on view public.member_posts is
  'ログイン済み利用者向けの投稿（詳細）。ブロックした相手・自分だけの非表示を除く。ミュートは適用しない。';

-- feed_posts：一覧・検索。member_posts に、話題ミュート・言葉ミュートを適用する。
create view public.feed_posts
  with (security_invoker = true) as
select m.*
from public.member_posts m
where (
    m.topic_id is null
    or not exists (
      select 1 from public.muted_topics t
      where t.user_id = auth.uid() and t.topic_id = m.topic_id
    )
  )
  and not exists (
    select 1 from public.muted_words w
    where w.user_id = auth.uid()
      and position(w.normalized_word in lower(normalize(m.body, nfkc))) > 0
  );

comment on view public.feed_posts is
  'ログイン済み利用者向けの一覧・検索の元。member_postsに話題・言葉のミュートを適用する。';

-- === コメントの取得 ===
-- ブロックした相手のコメント・返信と、自分だけの非表示にしたコメントを除く。
create or replace view public.member_comments
  with (security_invoker = true) as
select
  c.id,
  c.post_id,
  c.parent_comment_id,
  c.author_id,
  c.body,
  (c.deleted_at is not null) as is_deleted,
  c.created_at,
  c.edited_at,
  pr.nickname as author_nickname,
  pr.icon_key as author_icon_key,
  pr.avatar_path as author_avatar_path
from public.comments c
left join public.public_profiles pr on pr.id = c.author_id
where not exists (
    select 1 from public.blocks b
    where b.blocker_id = auth.uid() and b.blocked_id = c.author_id
  )
  and not exists (
    select 1 from public.hidden_items h
    where h.user_id = auth.uid() and h.target_type = 'comment' and h.target_id = c.id
  );

-- === 通知 ===
-- ブロックした相手が起こした通知は表示しない。
drop policy notifications_select_own on public.notifications;
create policy notifications_select_own
  on public.notifications
  for select
  to authenticated
  using (
    user_id = auth.uid()
    and (
      actor_id is null
      or not exists (
        select 1 from public.blocks b
        where b.blocker_id = auth.uid() and b.blocked_id = actor_id
      )
    )
  );

-- === 権限 ===
grant select on public.member_posts, public.feed_posts to authenticated;

-- トリガー関数は、APIから直接呼ばせない（関数のEXECUTEは作成時に全員へ付くため、明示的に外す）。
revoke all on function public.muted_words_before_write() from public, anon, authenticated;
grant execute on function public.muted_words_before_write() to service_role;
