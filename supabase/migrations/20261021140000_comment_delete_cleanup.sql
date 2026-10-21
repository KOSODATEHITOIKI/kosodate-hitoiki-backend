-- コメントを削除（ソフト削除）したとき、そのコメントへの通知・配信待ちのプッシュ・本人だけの非表示の記録が残らないようにする
-- （外部レビューの指摘）。
--
-- 以前は、本人の削除（delete_comment）だけが、これらを消していた。運営の削除（moderation_apply）は消さず、
-- 削除したコメントの通知が残り、削除のあとにプッシュが届き得た（プッシュの文面は定型文だが、削除済みの内容を指す）。
-- 後始末を「ソフト削除のトリガー」に集め、どの経路で削除しても、同じ後始末になるようにする。
-- 通知を消すと、配信待ちのプッシュ（push_deliveries）も連鎖して消える。
-- 運営から本人へのお知らせ（notification_type = 'moderation'）は、comment_idを持たないので残る。
create or replace function public.comments_before_soft_delete()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.deleted_at is not null and old.deleted_at is null then
    new.body := null;
    delete from public.hidden_items where target_type = 'comment' and target_id = old.id;
    delete from public.notifications where comment_id = old.id;
  end if;
  return new;
end;
$$;

-- 本人の削除：後始末は、上のトリガーが行う（経路ごとに重ねて書かない）。
create or replace function public.delete_comment(p_user_id uuid, p_comment_id uuid)
returns void
language plpgsql
set search_path = public
as $$
declare
  target record;
begin
  select author_id, deleted_at into target
  from public.comments where id = p_comment_id for update;

  if not found or target.deleted_at is not null then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if target.author_id <> p_user_id then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;

  -- 本文・本人だけの非表示・通知の後始末は、comments_before_soft_delete トリガーが行う。
  update public.comments set deleted_at = now() where id = p_comment_id;
end;
$$;
