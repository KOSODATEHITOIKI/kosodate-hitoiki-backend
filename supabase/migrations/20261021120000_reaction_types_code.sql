-- 共感・定型文（reaction_types）に、固定の名前（code）を足す（Issue #75）。
-- 画面のアイコンなどと結びつけるため。文言（label）は運営が直すことがあるが、codeは変えない。
-- 文言・種類のデータは、マイグレーションには入れない（文言は運営が直す。ローカルのテストにも影響させない）。
-- 初期データは、supabase/seeds/master_initial.sql（dev・本番とも、SQL Editorで手動で実行）。
alter table public.reaction_types add column code text;

alter table public.reaction_types
  add constraint reaction_types_code_format check (code is null or code ~ '^[a-z][a-z0-9_]{1,31}$');

create unique index reaction_types_code_key on public.reaction_types (code) where code is not null;

comment on column public.reaction_types.code is
  '画面のアイコン等と結びつける固定の名前（英小文字・数字・_、2〜32文字）。文言（label）を直しても変えない。nullは、アイコンとの対応がない定型文。';
