-- アカウント画像・利用規約同意・Storageの権限の検証（Issue #12）。
-- ニックネームの同時登録・変更に対する競合は、pgTAPでは検証できないため
-- supabase/tests/concurrency/run.sh で検証する。

BEGIN;
SELECT plan(16);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000a2');

INSERT INTO public.profiles (id, nickname) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'ユーザーA'),
  ('00000000-0000-0000-0000-0000000000a2', 'ユーザーB');

INSERT INTO public.terms_acceptances (user_id, terms_version) VALUES
  ('00000000-0000-0000-0000-0000000000a1', '2026-10'),
  ('00000000-0000-0000-0000-0000000000a2', '2026-10');

-- --- アカウント画像：イラスト選択とアップロードは排他 ---
SELECT lives_ok(
  $$update public.profiles set avatar_path = '00000000-0000-0000-0000-0000000000a1/a.webp'
    where id = '00000000-0000-0000-0000-0000000000a1'$$,
  'アップロード画像のパスだけを設定できる'
);

SELECT throws_ok(
  $$update public.profiles set icon_key = 'bear'
    where id = '00000000-0000-0000-0000-0000000000a1'$$,
  '23514',
  null,
  'アップロード画像とイラスト選択（icon_key）は同時に設定できない'
);

SELECT lives_ok(
  $$update public.profiles set avatar_path = null, icon_key = 'bear'
    where id = '00000000-0000-0000-0000-0000000000a1'$$,
  'アップロード画像を外してイラストに切り替えられる'
);

SELECT has_column('public', 'public_profiles', 'avatar_path',
  'public_profiles にアップロード画像のパスを含む（ニックネームと同じ公開範囲）');

SELECT hasnt_column('public', 'public_profiles', 'bio',
  'public_profiles にプロフィール本文（bio）は含まれない');

-- --- Storage：バケットは公開、書き込みはEdge Functionsのみ ---
SELECT is(
  (SELECT public FROM storage.buckets WHERE id = 'avatars'),
  true,
  'avatars バケットは公開URLで閲覧できる'
);

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';

SELECT throws_ok(
  $$insert into storage.objects (bucket_id, name, owner)
    values ('avatars', '00000000-0000-0000-0000-0000000000a1/direct.png', auth.uid())$$,
  '42501',
  null,
  'クライアントから avatars へ直接アップロードできない（確認を迂回させない）'
);

-- --- 利用規約同意の記録 ---
SELECT is(
  (SELECT count(*)::int FROM public.terms_acceptances),
  1,
  '利用規約の同意記録は本人の分だけ参照できる'
);

SELECT throws_ok(
  $$insert into public.terms_acceptances (user_id, terms_version)
    values ('00000000-0000-0000-0000-0000000000a1', '2026-11')$$,
  '42501',
  null,
  '利用規約の同意記録はクライアントから直接書き込めない'
);

RESET role;

-- --- プロフィール登録（create_profile） ---
INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000b1'),
  ('00000000-0000-0000-0000-0000000000b2');

SELECT is(
  public.create_profile('00000000-0000-0000-0000-0000000000b1', 'あおい', '自己紹介', '0〜1歳', null, '2026-10'),
  'created',
  '新規登録は created を返す'
);

SELECT is(
  (SELECT count(*)::int FROM public.terms_acceptances WHERE user_id = '00000000-0000-0000-0000-0000000000b1')
  + (SELECT count(*)::int FROM public.notification_settings WHERE user_id = '00000000-0000-0000-0000-0000000000b1'),
  2,
  '登録と同時に利用規約同意と通知設定が作られる'
);

SELECT is(
  public.create_profile('00000000-0000-0000-0000-0000000000b1', 'あおい', '自己紹介', '0〜1歳', null, '2026-10'),
  'exists',
  '応答が届かず再送された同じ登録は、重複せず exists を返す'
);

SELECT is(
  public.create_profile('00000000-0000-0000-0000-0000000000b1', 'べつの名前', null, null, null, '2026-10'),
  'conflict',
  '作成済みの利用者が別の名前で登録しようとすると conflict を返す'
);

SELECT throws_ok(
  $$select public.create_profile('00000000-0000-0000-0000-0000000000b2', 'あおい', null, null, null, '2026-10')$$,
  '23505',
  null,
  '他の人が使っている名前での登録は一意制約で拒否される'
);

SELECT is(
  (SELECT count(*)::int FROM public.terms_acceptances WHERE user_id = '00000000-0000-0000-0000-0000000000b2'),
  0,
  '登録が失敗したときは利用規約同意も残らない（中途半端な登録を作らない）'
);

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000b2';

SELECT throws_ok(
  $$select public.create_profile('00000000-0000-0000-0000-0000000000b2', 'ゆうと', null, null, null, '2026-10')$$,
  '42501',
  null,
  'クライアントは create_profile を直接実行できない'
);

RESET role;

SELECT * FROM finish();
ROLLBACK;
