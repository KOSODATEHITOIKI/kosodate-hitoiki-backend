# CLAUDE.md

このリポジトリで作業するAIエージェント（Claude Code）向けのルール集約ファイル。個別ドキュメントに散らばる決定事項ではなく、**作業の進め方そのものに関するルール**をここにまとめる。姉妹リポジトリ（kosodate-hitoiki本体、kumayokeru-app／kumayokeru-backend、burari-date、tekushare-app）と運用方針を揃えることを前提とする。

## このリポジトリについて

kosodate-hitoiki（子育てのぐち・相談・コツや体験談を共有するSNS、Flutter製）のバックエンド。Supabase（DB・RLS・Edge Functions）を管理する。フロントエンドは別リポジトリ [kosodate-hitoiki](https://github.com/naka328/kosodate-hitoiki)。

現状はDBスキーマ・RLS・DBテスト（Issue #10）、送信前チェックの共通モジュール（#11）、プロフィール系のEdge Functions（#12）、投稿・コメント・返信のAPI（#13）、ブロック・非表示・ミュートの取得への適用（#14）、共感・保存（#15）、投稿の検索（#16）、通報・運営の対処（#17）、登録直後の投稿頻度制限・新規登録の停止（#18）、通知・プッシュ配信の基盤（#19）、退会・保持期限の削除（#20）まで実装済み。バックアップ・運用などは未実装（#21以降）。進捗の正は親Issue #6のチェックリスト。

## 一次情報と資料の優先順位

1. **[Notion要件定義書](https://app.notion.com/p/3e95b8f5ffee8171bf86f976d5d5b2ec)** が仕様の一次情報。
2. 本リポジトリの`docs/`が、Notionの決定事項をバックエンド実装の観点で整理したもの。Notionと矛盾する場合は[未決事項.md](docs/未決事項.md)に記録し、無断で判断しない。
3. GitHub Issue（特に親Issue [#6](https://github.com/nakayu206/kosodate-hitoiki-backend/issues/6)）が実装工程と依存関係を管理する。

`docs/`配下は共通の書式を使う：**決定済み**＝資料で明示的に決まった要件、**設計案**＝実現方法の提案（採用確定ではない）、**未決定**＝判断が残るもの。この3つを混同しない。特に**未決定のまま実装しない**（推奨案があっても、ユーザーの判断を得るまで確定事項として扱わない）。

| ドキュメント | 内容 |
|---|---|
| [バックエンド設計](docs/バックエンド設計.md) | 担当範囲、権限、処理の境界 |
| [データ設計案](docs/データ設計案.md) | 経緯・論点の記録（テーブル定義そのものではない） |
| [スキーマ定義](docs/スキーマ定義.md) | 確定したテーブル定義・ER概要（実装の一次資料） |
| [認証設定](docs/認証設定.md) | 認証（メール・Google・Apple）の担当境界・外部設定・検証手順 |
| [送信前チェック評価](docs/送信前チェック評価.md) | 送信前チェックの判定方式・閾値の初期案、日本語の評価例と結果 |
| [検索方式の実測](docs/検索方式の実測.md) | 日本語検索の方式（PGroonga）を実測して選んだ記録 |
| [運営の二段階認証](docs/運営の二段階認証.md) | 運営者を二段階認証（TOTP）で守る仕組みと、管理者の手作業 |
| [退会とデータの保持](docs/退会とデータの保持.md) | 退会で消えるもの・残るもの、保持期限、残存データの一覧 |
| [権限表](docs/権限表.md) | 未ログイン／本人／他人／運営者の権限マトリクス |
| [API契約](docs/API契約.md) | リクエスト／レスポンス例、エラー、ページング |
| [開発・運用方針](docs/開発・運用方針.md) | ブランチ、環境構築、CI、バックアップ |
| [未決事項](docs/未決事項.md) | 未決定の項目、後回しにする項目、資料の不整合 |

新しく仕様を確認・決定したら、該当するdocsファイルを更新し、[未決事項.md](docs/未決事項.md)の該当項目を除去または更新する。ドキュメントを更新せずに実装だけ進めない。

## ブランチ・PR・Issueの運用

姉妹リポジトリ（kosodate-hitoiki本体）の[環境とブランチ運用ガイド](https://github.com/nakayu206/kosodate-hitoiki/blob/main/docs/環境とブランチ運用.md)に合わせ、**Git Flow**を採用する。

```text
main                  ← リリース済みの状態のみ
  └─ develop          ← 開発中の最新状態を集約する統合ブランチ
       ├─ feature/xxx ← develop から分岐、develop 宛てにPR
       └─ fix/xxx      ← 同上
  └─ hotfix/xxx       ← 本番の緊急修正。main から分岐し、main と develop の両方へ反映
```

- 作業は必ず`develop`から作業ブランチを切る。`main`・`develop`へ直接コミット・pushしない。
- 変更は必ず関連Issueを紐づけたPRで提案する。PR本文は`.github/pull_request_template.md`の書式（📝説明／🔗関連Issue／📋変更内容／✅チェックリスト／📸スクリーンショット／🚀備考）に従う。
- PRのbaseが`develop`の場合、Issueの自動クローズはデフォルトブランチ（`main`）の設定に依存するため機能しない。マージ後は手動でIssueの状態（close／進捗コメント）を確認する。
- Issue・PRテンプレートは`kosodate-hitoiki`と共通のものを使う（Bug・Logic・UIテンプレート）。
- 実装は親Issue #6の依存関係表に従う。前提Issueが完了していない工程を先送りで着手しない（設計・調査の先行着手は可）。

## コミット・PRメッセージ

- 日本語で、変更の意図（なぜ）が分かるように書く。
- コミットメッセージ・PR説明の末尾に付ける attribution（Co-Authored-By等）は、呼び出し元（Claude Codeのシステム設定）の指示に従う。本ファイルでは固定しない。

## セキュリティ上、絶対に崩してはいけない設計方針

[スキーマ定義.md 10節](docs/スキーマ定義.md)で確定した方針。マイグレーション・RLSポリシーを追加・変更する際は必ず守る。

- **送信前チェック対象のテーブル**（`profiles`のnickname/bio、`posts`、`comments`）には、認証済み利用者向けのINSERT/UPDATE/DELETE RLSポリシーを絶対に追加しない。書き込みはEdge Functions（`service_role`、RLSをバイパスする）経由のみに限定し、クライアントの直接書き込みで送信前チェックを迂回できる経路を作らない。`reports`・`moderation_actions`・`account_restrictions`・`nickname_reservations`・`app_settings`も同様。
- 自由記述を伴わない単純な関係のトグル（`saved_posts`・`hidden_items`・`blocks`・`muted_topics`・`muted_words`・`notification_settings`）は本人限定のRLSで直接操作を許可してよい。`push_devices`は、同じ端末を別の人が使い始めたときに前の持ち主宛ての通知が届かないよう、登録を`register_push_device`（持ち主を移す）に一本化し、直接のINSERT/UPDATEは許可しない（参照と削除は本人だけ）。`push_deliveries`（配信キュー）・`write_events`・`app_settings_history`は`service_role`専用。`reactions`は、ブロック・利用停止・非表示の確認を迂回させないため、書き込みをDB関数（service_role専用）に一本化している。
- 件数のように「本人にだけ集計値を見せる」要件（共感件数、公開コメント件数）は、生のテーブルSELECTではなく`security definer`関数で提供する。RLSの行フィルタだけでは列単位・集計単位の制限を表現できないため。
- 新しいテーブルを追加したら**必ず**`alter table ... enable row level security;`を書く。有効化を忘れると、Supabaseの自動生成APIで全件公開されてしまう。
- 公開用ビュー（`public_profiles`のように本文以外だけを公開する用途）は`security_invoker`を付けない（オーナー権限で実行、RLSをバイパスして公開列だけを見せる）。逆に、既存のRLSに従わせたいビュー（`public_posts`）は`security_invoker = true`を付ける。用途を混同しない。

- **APIの公開権限は deny-by-default**。`anon`・`authenticated`へのテーブル・ビュー・関数の権限は、移行で明示したものだけ。新しいオブジェクトを追加したら、必要な権限を同じ移行で付け、`supabase/tests/api_privileges_test.sql`の期待値も更新する。関数のEXECUTEは既定で全員に付くため、不要なものは必ずrevokeする。

## ローカル開発・テスト

```sh
npm ci                      # 依存関係インストール（markdownlint, prettier, supabase CLI）
npm run check                # Markdown・設定ファイルのlint
npm run supabase:start       # ローカルSupabaseスタック起動（Docker Desktop必須）
npx supabase db reset        # マイグレーション・シードからDBを再構築
npx supabase test db         # pgTAPテスト（supabase/tests/）を実行
npm run test:concurrency     # 同時実行の競合テスト（要 supabase start）
npm run supabase:stop        # 停止
npm run functions:check      # Edge Functionsのfmt・lint・型検査（Deno、supabase/functions/）
npm run functions:test       # Edge FunctionsのDenoテスト
npm run test:functions-integration  # Functionsの配線の結合テスト（要 supabase start）
npm run test:functions-smoke        # Edge Runtime上で全Functionが読み込めるかの確認（要 supabase start）
```

マイグレーションを追加・変更したら、必ず`npx supabase db reset`と`npx supabase test db`をローカルで実行してから push する。CIの`Database (migrations and RLS)`ジョブでも同じ検証が走る。

## 秘密情報の扱い

APIキー・特権キー・本番の接続情報をリポジトリに含めない。`.env.example`には変数名と用途だけを書く。本番の接続情報はデプロイ先のシークレットストアでのみ管理し、ローカルの`.env`にも本番の値を書かない（[開発・運用方針](docs/開発・運用方針.md)参照）。
