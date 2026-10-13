# API契約

更新日：2026-09-29。Issue #9として、Flutterアプリが接続実装できるレベルのリクエスト／レスポンス例を定義する。[スキーマ定義](スキーマ定義.md)・[権限表](権限表.md)の実現方式。実際のURL・関数名は#11〜#13の実装時に確定し、本書は契約の合意点として扱う。

## 1. 共通事項

### 実行経路の使い分け

| 種類 | 経路 | 例 |
|---|---|---|
| 単純な読み取り | PostgRESTの自動生成API（RLSで保護） | 投稿一覧、コメント一覧 |
| 外部APIを伴う処理 | Edge Functions | 送信前チェックを伴う投稿・コメントの作成／編集 |
| 複数テーブルを不可分に更新する処理 | DB関数（`rpc`経由）またはEdge Functions内のトランザクション | 通報の登録と自動一時非表示判定、退会処理 |

Edge Functionsのベースパスは`/functions/v1/`（ローカルは`http://127.0.0.1:54321/functions/v1/`、[開発・運用方針](開発・運用方針.md)参照）。PostgRESTは`/rest/v1/`。

### 認証

すべての書き込み系・会員限定の読み取り系はSupabase Authが発行するJWTを`Authorization: Bearer <token>`で送る。未ログイン時はanon keyのみで呼び出し、[権限表](権限表.md)で「未ログイン」に○がある操作のみRLSが許可する。

### エラー形式（Edge Functions）

```json
{
  "error": {
    "code": "VALIDATION_FAILED",
    "message": "本文は1,000文字以内で入力してください。",
    "details": { "field": "body", "limit": 1000 }
  }
}
```

主なエラーコード：

| code | HTTPステータス | 用途 |
|---|---|---|
| UNAUTHENTICATED | 401 | 未ログイン |
| FORBIDDEN | 403 | 権限なし・ブロック・利用停止中 |
| NOT_FOUND | 404 | 対象が存在しない、または一時非表示で非表示中 |
| VALIDATION_FAILED | 422 | 文字数超過・空入力等 |
| MODERATION_REJECTED | 422 | 送信前チェックで送信不可と判定 |
| MODERATION_CONFIRM_REQUIRED | 409 | 送信前チェックで確認表示が必要（[バックエンド設計](バックエンド設計.md)4節） |
| MODERATION_UNAVAILABLE | 503 | 外部Moderation APIが利用不可（保存はブロックし再試行を促す。決定済み） |
| INTERNAL_ERROR | 500 | 想定外のエラー（内部の詳細・本文は返さない） |
| RATE_LIMITED | 429 | 登録直後のレート制限、新規登録停止中 |
| CONFLICT | 409 | 同時更新・受付状態の競合 |

PostgRESTのエラーはPostgRESTの標準形式（`message`/`code`/`details`/`hint`）をそのまま返す。

### ページング

新着順一覧はキーセット方式を用い、重複・抜けを避ける。

```http
GET /rest/v1/posts?select=*&order=created_at.desc,id.desc&limit=20
GET /rest/v1/posts?select=*&order=created_at.desc,id.desc&limit=20&or=(created_at.lt.2026-09-29T00:00:00Z,and(created_at.eq.2026-09-29T00:00:00Z,id.lt.<前ページ最後のid>))
```

レスポンスヘッダ`Content-Range`で全体件数の目安を返す（PostgRESTの標準機能）。

### 再送・同時操作

- 作成系のEdge Functionsは`Idempotency-Key`ヘッダ（クライアント生成のUUID）を受け付け、同一キーでの再送は最初の結果をそのまま返す（二重投稿防止）。
- 受付状態・反応モードの変更とコメント作成が競合した場合はDBトランザクション内で受付状態を再確認し、競合時は`CONFLICT`を返す。

## 2. 認証・プロフィール

### プロフィール取得（公開ニックネームのみ）

```http
GET /rest/v1/public_profiles?id=eq.<user_id>&select=id,nickname,icon_key,avatar_path
```

`public_profiles`はbio・child_age_rangeを含まない公開ビュー（[スキーマ定義](スキーマ定義.md)2節、RLSでプロフィール本文を保護）。

### プロフィール取得（本人）

```http
GET /rest/v1/profiles?id=eq.<自分のuser_id>&select=*
Authorization: Bearer <token>
```

### プロフィール登録

```http
POST /functions/v1/profile-create
Authorization: Bearer <token>
{
  "nickname": "はなこ",
  "bio": "よろしくお願いします",
  "child_age_range": "0〜1歳",
  "icon_key": null,
  "terms_version": "2026-10",
  "confirmed": false
}
```

- ニックネーム2〜12文字（絵文字等も1文字、全角・半角はNFKC後に数える）、自己紹介100文字まで。ニックネーム・自己紹介は送信前チェックを通す（`confirmed: true`で確認後の再送）。`terms_version`は必須（利用規約への同意を記録）。
- 成功：新規作成は`201`、同じ内容の再送（作成済み）は`200`。レスポンス`{ "id": "<user_id>", "support_notice": false }`。`support_notice`は本人にだけ相談先を案内するためのフラグ。
- 別のニックネームで作成済みなら`409 CONFLICT`。他の人が使用中の名前は`409 CONFLICT`、旧名の予約中は`422 VALIDATION_FAILED`。
- プロフィール・利用規約同意・通知設定は1トランザクションで作られ、失敗時は何も残らない。

### プロフィール更新

```http
PATCH /functions/v1/profile-update
Authorization: Bearer <token>
{ "bio": "更新しました", "child_age_range": "2〜3歳", "icon_key": "bear_01" }
```

指定した項目だけ更新する（空の更新は`422`）。自己紹介は送信前チェックを通す。`icon_key`（イラスト）を選ぶと、アップロード画像は外れてファイルも削除される（どちらか一方）。

### アカウント画像

```http
PUT /functions/v1/profile-avatar
Authorization: Bearer <token>
Content-Type: image/png
<画像のバイナリ>

DELETE /functions/v1/profile-avatar
Authorization: Bearer <token>
```

- 形式はJPEG・PNG・WebP、2MBまで（アプリ側で512px四方に縮小して送る）。Content-Typeとファイルの中身（先頭のバイト列）が一致しない場合は`422`。
- 保存前にOpenAI Moderationの画像判定で確認し、不適切なら`422 MODERATION_REJECTED`、外部API障害なら`503 MODERATION_UNAVAILABLE`（保存しない）。
- 成功：`200`、`{ "avatar_path": "<user_id>/<id>.png" }`。公開URLはStorageの`avatars`バケットの公開URL＋`avatar_path`。差し替え時は旧画像を削除する。`DELETE`はアップロード画像を外してファイルを削除する。
- クライアントからStorageへ直接アップロードすることはできない。

### ニックネーム変更

```http
POST /functions/v1/profile-nickname
Authorization: Bearer <token>
{ "nickname": "あたらしい名前", "confirmed": false }
```

成功時`200`、旧名を`nickname_reservations`へ30日予約。初回の変更は制限なし、以降は前回の変更から30日空ける（違反は`422 VALIDATION_FAILED`）。旧名は他の人が30日使用できない（本人は再利用可）。送信前チェックあり。

## 3. 投稿

### 一覧取得（未ログイン可）

```http
GET /rest/v1/public_posts?select=id,post_type,topic_id,body,created_at,comment_count&order=created_at.desc,id.desc&limit=20
```

`public_posts`は一時非表示・削除済みを除外し、共感件数・通報情報を含まない公開ビュー（[権限表](権限表.md)2節）。

### 投稿作成

```http
POST /functions/v1/posts
Authorization: Bearer <token>
Idempotency-Key: <uuid>
{
  "post_type": "guchi",
  "topic_id": null,
  "body": "今日は本当に大変だった…",
  "reaction_mode": "quiet_support"
}
```

レスポンス`201`：

```json
{ "id": "b3c1...", "created_at": "2026-09-29T03:00:00Z" }
```

送信前チェックで`MODERATION_CONFIRM_REQUIRED`が返る場合、クライアントは確認表示後に`{"...": "...", "confirmed": true}`を付けて再送する。`MODERATION_REJECTED`は`confirmed`を付けても覆らない。エラーの`details.reasons`には理由コード（`banned_word`・`pii_phone`・`harassment`等）だけを入れ、本文は含めない。

**設計案**：自分や子どもへの危害をほのめかす内容は投稿を止めず、書き込んだ本人へのレスポンスにだけ`"support_notice": true`を含め、クライアントが相談先を案内する。他の利用者へは公開しない（詳細は[送信前チェック評価](送信前チェック評価.md)）。

### 反応モード・受付状態の変更

```http
PATCH /functions/v1/posts/{id}/reaction-mode
Authorization: Bearer <token>
{ "reaction_mode": "want_comments", "comment_acceptance": "open" }
```

本人以外は`FORBIDDEN`。

## 4. コメント・返信

### 一覧取得（ログイン必須）

```http
GET /rest/v1/comments?post_id=eq.<post_id>&select=id,author_id,parent_comment_id,body,deleted_at,updated_at&order=created_at.asc
Authorization: Bearer <token>
```

`deleted_at`が非nullの行は`body`がnullで返る。クライアントは「削除済み」表示に置き換える。一時非表示（`hidden_at`）の行はRLSで除外される（運営者を除く）。

### コメント・返信の作成

```http
POST /functions/v1/comments
Authorization: Bearer <token>
Idempotency-Key: <uuid>
{ "post_id": "b3c1...", "parent_comment_id": null, "body": "わかります、私も同じです" }
```

受付状態が`closed`、投稿者にブロックされている、利用停止中のいずれかであれば`FORBIDDEN`。`parent_comment_id`が返信への返信の場合は`VALIDATION_FAILED`。

### コメント編集・削除

```http
PATCH /functions/v1/comments/{id}
Authorization: Bearer <token>
{ "body": "書き直した内容" }

DELETE /functions/v1/comments/{id}
Authorization: Bearer <token>
```

削除は`deleted_at`を設定するソフト削除（[スキーマ定義](スキーマ定義.md)3節）。

## 5. リアクション

```http
PUT /functions/v1/posts/{id}/reaction
Authorization: Bearer <token>
{ "reaction_type_id": 3 }

DELETE /functions/v1/posts/{id}/reaction
Authorization: Bearer <token>
```

`PUT`は登録・変更を1操作で扱う（`on conflict do update`）。件数は`reactions`テーブルへの直接SELECTでは取得できない（他者の行が見えてしまうため）。投稿者本人と運営者のみ以下のRPC（`security definer`関数）で取得する（運営者にも共感の行そのものは見せない）（[スキーマ定義](スキーマ定義.md)4節）：

```http
POST /rest/v1/rpc/get_post_reaction_count
Authorization: Bearer <token>
{ "p_post_id": "<id>" }
```

投稿者本人以外が呼び出した場合は`0`が返る（存在の有無を区別できないようにする）。

## 6. 保存・非表示・ブロック・ミュート

```http
POST   /rest/v1/saved_posts        { "post_id": "..." }
DELETE /rest/v1/saved_posts?post_id=eq.<id>
POST   /rest/v1/hidden_items       { "target_type": "post", "target_id": "..." }
POST   /rest/v1/blocks             { "blocked_id": "..." }
DELETE /rest/v1/blocks?blocked_id=eq.<id>
POST   /rest/v1/muted_topics       { "topic_id": 3 }
POST   /rest/v1/muted_words        { "word": "..." }
```

いずれもRLSで本人の行のみ操作可能（[権限表](権限表.md)5節）。PostgRESTの一意制約違反は`409`（PostgRESTの標準応答）として返る。

## 7. 通報・運営

### 通報

```http
POST /functions/v1/reports
Authorization: Bearer <token>
{ "target_type": "post", "target_id": "...", "reason": "personal_info", "detail": "" }
```

同一通報者・同一対象の未対応通報が既にある場合は既存行をそのまま返す（重複作成しない、[スキーマ定義](スキーマ定義.md)6節の部分unique制約）。DB関数内で「異なる通報者3人到達」を判定し、到達時は対象の`hidden_at`を設定する。

### 運営操作（運営者専用）

```http
POST /functions/v1/moderation/actions
Authorization: Bearer <admin token>
{ "target_type": "post", "target_id": "...", "action": "unhide", "reason": "誤検知のため再表示" }
```

`action=unhide`のとき、対象への未対応通報をまとめて`resolved_at`に更新する（[スキーマ定義](スキーマ定義.md)6節）。`action=suspend`のときは`account_restrictions`へ次段階の制限を作成する。二段階認証済みでないセッションは`FORBIDDEN`。

## 8. 通知

```http
GET   /rest/v1/notifications?select=*&order=created_at.desc&limit=20
Authorization: Bearer <token>

PATCH /rest/v1/notifications?id=eq.<id>          { "is_read": true }
PATCH /rest/v1/notification_settings?user_id=eq.<自分> { "comments_enabled": false }
POST  /rest/v1/push_devices                       { "platform": "ios", "device_token": "..." }
```

共感の集約通知（`reaction_digest`）の生成方式・頻度は未決定のため、生成側の実装は#19で追加する。

## 9. 本書の対象外・今後確定する事項

- 具体的な関数名・URLパス、OpenAPI／型定義生成の方式は#11〜#13で確定する。
- 認証（サインアップ・ログイン・OAuth）のエンドポイントはSupabase Auth標準APIを利用し、本書では扱わない。
- レート制限（`RATE_LIMITED`）の具体的な閾値は`app_settings`の値に従う。既定値は未決定（[未決事項](未決事項.md)）。
- 日本語検索のクエリ形式は方式未確定のため、一覧APIの`q`パラメータ等は#16で追加する。

## 参照

- [スキーマ定義](スキーマ定義.md)
- [権限表](権限表.md)
- [バックエンド設計](バックエンド設計.md)
- [未決事項](未決事項.md)
