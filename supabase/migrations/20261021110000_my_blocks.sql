-- ブロック管理（解除）の画面に、ブロックした相手のニックネームとアイコンを出すためのビュー（Issue #75）。
-- これまでは blocks が blocked_id を返すだけで、表示名を得る手段がなかった
-- （public_profiles は、自分と「公開中の投稿・コメントの投稿者」に限られ、ブロックした相手が出る保証がない）。
--
-- security_invoker を付けない（オーナー権限で実行し、profiles のRLSを越えて、ニックネーム・アイコンだけを読む）。
-- そのかわり、where で「自分がブロックした行」だけに絞る。ブロックされた側・第三者からは、0件にしか見えない
-- （ブロックされている事実を推測させない）。
create view public.my_blocks as
select
  b.blocked_id,
  p.nickname as blocked_nickname,
  p.icon_key as blocked_icon_key,
  p.avatar_path as blocked_avatar_path,
  b.created_at
from public.blocks b
join public.profiles p on p.id = b.blocked_id
where b.blocker_id = auth.uid();

comment on view public.my_blocks is
  '自分がブロックした相手の表示名（ニックネーム・アイコン）。本人だけが読める。解除は blocks の DELETE（blocked_id 指定）。';

-- 未ログインには付けない（deny-by-default）。
grant select on public.my_blocks to authenticated;
