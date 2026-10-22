# Flutter結合ガイド

更新日：2026-10-21。Issue #22（Flutter結合・権限・公開前受入検証）の準備として、**フロント（[kosodate-hitoiki](https://github.com/KOSODATEHITOIKI/kosodate-hitoiki)）がバックエンドへ接続するために必要な作業**と、**受入試験の対応表**をまとめる。API仕様の一次資料は[API契約](API契約.md)。

> **この資料の確かさ**：フロントの現状は、`lib/`のファイル名・クラス名・コメントを読んで把握したもの（2026-10-21時点）。各画面の中身まで1行ずつ確認したわけではないので、着手時に、対象の画面を読み直して確かめる。**決定済み**＝API契約・権限表で決まっていること。**設計案**＝この資料の提案（採用は未確定）。

## 1. 現状

| 項目 | 状態 |
|---|---|
| 接続先の設定 | `core/config/supabase_config.dart`が**プレースホルダー**（`your-project.supabase.co`／`your-anon-key`）。実際の値に差し替える（匿名キーは公開してよい値） |
| 認証 | `AuthRepository`にメール・Google・Appleのログイン処理がある。画面（`auth_page.dart`）は「フォームと画面遷移のみ」で、認証は未接続 |
| 投稿・検索・保存・プロフィール | **モックのみ**（`data/mock/`、`MockPostRepository`、`MockProfileRepository`）。`PostRepository`・`ProfileRepository`は抽象で、Supabase実装が未作成 |
| 共感 | `mock_reaction_providers.dart`のモック（端末内だけで完結） |
| 通知 | `mock_notifications.dart`のモック |
| 送信前チェック | `ContentModerationRepository`が独立の`check-content`関数を呼ぶ作りで、**現在のバックエンドと整合しない**（バックエンドは、投稿・コメント作成APIの中で送信前チェックを行う）。この呼び出しは廃止する |
| テスト | Widgetテストが画面ごとにある（モックで動く） |

## 2. 接続の順序（設計案）

前の段が動いてから次へ進む。各段で、**dev環境の実機**で確認する。

| 段 | 内容 | 使うAPI | 主な画面 |
|---|---|---|---|
| 0 | 接続先の差し替え。dev・prodの値を、`main_dev.dart`・`main_prod.dart`の環境ごとに持たせる | ― | ― |
| 1 | 登録・ログイン。ログイン後、**プロフィール未登録ならプロフィール登録へ**（API契約2節。利用規約の同意を同時に送る） | Supabase Auth、`profile-create` | `auth_page`、`welcome_page`、`profile_edit_page` |
| 2 | 読み取り（未ログインを含む）：新着一覧、検索、投稿の詳細 | `public_posts`、`feed_posts`、`member_posts`、`search_posts` | `home_page`、`search_page`、`post_detail_page` |
| 3 | 投稿・コメント・返信の作成と編集・削除。送信前チェックの応答（確認・拒否・利用不可）の表示 | `posts`、`comments` | `compose_page`、`compose_review_page`、`post_detail_page` |
| 4 | 共感・保存・非表示・ブロック・ミュート | `reaction`、`saved_posts`、`hidden_items`、`blocks`、`muted_*` | `post_card`、`reaction_picker`、`block_management_page` |
| 5 | 通報 | `reports` | `report_page` |
| 6 | マイページ（自分の投稿・「確認中」・保存） | `my_posts`、`saved_post_list`、`get_post_reaction_count` | `mypage_page` |
| 7 | 通知（一覧・既読・設定）とプッシュ（端末の登録・解除） | `notifications`、`notification_settings`、`register_push_device`（要FCM。Firebaseの設定は管理者の手作業） | `notifications_page`、`notification_settings_page` |
| 8 | プロフィール編集・画像・ニックネーム変更、退会 | `profile-update`、`profile-avatar`、`profile-nickname`、`account-delete` | `profile_edit_page`、`withdrawal_page`、`settings_page` |

運営の画面（通報一覧・対処）は、アプリの画面を作らず、**運営者はスクリプトとダッシュボードで扱う**方針かどうかを、Notionの要件で確認してから決める（未確認）。二段階認証の登録は、アプリの画面なしでできる（[運営の二段階認証](運営の二段階認証.md)）。

## 3. フロントが対応する点（API契約から）

バックエンドが**決めている振る舞い**のうち、フロントが取りこぼしやすいもの。

| 項目 | 内容 | 根拠 |
|---|---|---|
| エラーの形 | Edge Functionsは`{ "error": { "code", "message", "details" } }`。PostgRESTは標準形式（`message`／`code`）。2種類を、共通の例外にそろえる | API契約1節 |
| 送信前チェックの応答 | `MODERATION_CONFIRM_REQUIRED`（409）は、確認表示のあと`confirmed: true`で再送。`MODERATION_REJECTED`（422）は覆らない。`MODERATION_UNAVAILABLE`（503）は再試行を促す | 同上 |
| 二重送信の防止 | 作成系は`Idempotency-Key`（UUID）を付ける。**再送のときは同じキーを使う** | 同上 |
| 相談先の案内 | 作成の応答の`support_notice: true`のときだけ、本人に相談先を案内する | API契約3節 |
| ブロックを推測させない | ブロックされた側の失敗は、汎用のエラー（`unavailable`）。**ブロックを示す文言を出さない** | API契約6節 |
| 制限・停止 | `403 restricted`（利用停止中）、`429 RATE_LIMITED`（`new_user_limit`／`request_limit`／`signup_halted`。`retry_at`で解除の目安を出せる） | API契約7節 |
| コメントの表示 | 削除済み（`is_deleted`）は「削除済み」、編集済み（`edited_at`）は「編集済み」、返信は`parent_comment_id`で親の下 | API契約4節 |
| 「確認中」 | 一時非表示の自分の投稿・コメントは、`under_review`で「確認中」と表示（本人だけ） | API契約7節 |
| 画像 | JPEG・PNG・WebP、2MBまで。**512px四方に縮小して送る**（アプリ側）。Storageへ直接アップロードしない | API契約2節 |
| 退会 | 「元に戻せません」と確認してから呼ぶ。`403 reauth_required`なら再ログインを求める。運営者は`409 operator_registered` | API契約2節 |
| プッシュ | ログイン時に`register_push_device`、ログアウト時に`push_devices`の削除。通知の文面は定型文のみで、タップで通知IDから取得して表示 | API契約8節 |
| 投稿者の表示 | 未ログインの一覧は`public_posts`（`author_id`なし）。ログイン済みは`feed_posts`（`author_id`あり） | API契約3・6節 |
| 反応 | 自分の投稿への共感は暫定で不可（`not_owner`）。コメント受付が終了していても共感はできる | API契約5節 |

## 4. 外部サービスの設定（管理者の手作業）

| 項目 | 状態 |
|---|---|
| OAuthの戻り先（ディープリンク） | **決定（2026-10-22、運営）：`kosodatehitoiki://auth-callback`**。Supabaseの「Redirect URLs」に登録済み（管理者の報告。prodは、リリース時に同じ値を登録）。アプリ側は実装済み（フロント PR #112）。パスワード再設定・Googleログインの通しの確認は、これから（[認証設定](認証設定.md)） |
| Apple ログイン | **フェーズ2**（決定済み）。**iOSのApp Store審査では、Googleなどの外部ログインを出す場合、Appleでサインインの提供が求められる場合がある**ため、iOSのリリース時期に影響する。リリース前に、審査の要件を確認する |
| メール送信（SMTP） | 本番は、Supabase標準のメール送信に回数の制限があるため、**専用の送信サービスが必要**。**決定（2026-10-22）：Resend＋独自ドメイン`kosodate-hitoiki.com`**。dev：設定済み（日本語の確認メールが届く）。prod：リリース時に設定 |
| FCM（Firebase） | プッシュを使うとき。`FCM_SERVICE_ACCOUNT_JSON`をEdge Functionsのシークレットに登録（[運用手順](運用手順.md)） |
| 利用規約・プライバシーポリシー | 文面は未作成。`terms_version`を、登録時に送る |

## 5. 受入試験の対応表（#22の1項目め）

「未ログイン／本人／他人／ブロック対象／停止中／運営者」の振る舞いは、バックエンドでは**DBの試験・結合試験で、すでに確かめている**。#22では、**フロントを通して、同じ振る舞いが画面に出る**ことを、dev環境の実機で確かめる。

| 観点 | バックエンドの検証（実施済み） | #22で確認すること（フロント経由・実機） |
|---|---|---|
| 未ログインの閲覧（公開投稿のみ、`author_id`なし） | `rls_test`・`api_privileges_test`・`post_search_test` | 未ログインで一覧・検索・詳細が見え、コメント・共感は登録案内になる |
| 本人の操作（編集・削除・受付状態） | `posts_comments_test`、結合試験 | 自分の投稿だけに編集・削除の操作が出る |
| 他人の投稿の操作 | `posts_comments_test`・`rls_test` | 他人の投稿に編集・削除が出ない／直接叩いても拒否される |
| ブロック・非表示・ミュート | `blocks_mutes_test` | ブロックした相手の投稿・コメントが消える。ブロックされた側が、理由を推測できない失敗表示になる |
| 停止中 | `rate_limit_test`、`reports_moderation_test` | 停止中は書き込みが拒否され、再ログインしても書けず、案内が出る |
| 登録直後の制限・新規登録停止 | `rate_limit_test` | 制限時の表示（`retry_at`）、停止中の登録の表示 |
| 運営者（二段階認証つき） | `reports_moderation_test`、dev実機（aal1→403、aal2→200） | 運営者以外には、運営の機能の存在が見えない |
| 登録→投稿→交流→通知→通報→退会 | 結合試験（`supabase/tests/functions/`） | 一連の流れを、1人の利用者で通しで確認する |
| 画像（メタデータ除去、拒否） | `review_fixes_test`、画像の結合試験 | 端末で撮った写真（位置情報つき）を送り、公開URLの画像に位置情報が残らない |
| 退会後の残存 | `withdrawal_test`、[退会とデータの保持](退会とデータの保持.md) | 退会後に、公開URL・一覧から消えている |

## 6. #22の残り3項目（結果の記録）

| 項目 | 方法 | 状態 |
|---|---|---|
| モデレーション精度 | [送信前チェック評価](送信前チェック評価.md)の評価例を、**実際のOpenAI Moderation**で再評価し、結果を記録（実際のキーが必要） | 初期案の評価は済み。実キーでの再評価は未実施 |
| 復旧試験 | [運用手順](運用手順.md)5節。`verify-local.sh`はローカルで成功。**クラウドでの復元試験は、保管先が決まってから** | 保管先が未定 |
| 想定負荷 | 想定の利用者数・同時接続数が未定。**決めてから、負荷の試験を設計する** | 想定が未決定 |
| 公開可否の判断材料 | [運用手順](運用手順.md)7節（リリース前の必須確認）と、[未決事項](未決事項.md)をまとめて、ユーザーへ提示 | 未確認の項目が残る |

## 7. 次にやること

1. （ユーザー）フロントの実装を、**どのリポジトリ・誰が・いつ**進めるかを決める。バックエンドのリポジトリでは、フロントのコードは変更しない。
2. （ユーザー）運営の画面をアプリに作るか、ダッシュボードとスクリプトで済ませるかを、Notionの要件で確認する。
3. 接続の順序（2節）の段0・1から、フロントのリポジトリで着手する。段ごとに、dev環境で動作を確認する。
4. 段が進むたびに、5節の表のうち、確認できた行を記録する。
