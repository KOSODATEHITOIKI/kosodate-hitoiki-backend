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
- **送信前チェックの結果（`MODERATION_CONFIRM_REQUIRED` 409、`MODERATION_REJECTED` 422、`MODERATION_UNAVAILABLE` 503）では、保存されず、キーも使われない**（キーが確保されるのは、保存の処理の中。結合テストで確認済み）。そのため、**409のあと、同じキーで`confirmed: true`を付けて再送してよい**。**推奨：1回の「投稿する」操作につき1つのキーを作り、確認後の再送や通信失敗の再送でも、同じキーを使い回す**（キーを変えると、再送の結果が不明なとき、二重に投稿されるおそれがある）。新しい投稿を始めるときに、新しいキーにする。
- 受付状態・反応モードの変更とコメント作成が競合した場合はDBトランザクション内で受付状態を再確認し、競合時は`CONFLICT`を返す。

## 2. 認証・プロフィール

### プロフィール取得（ログイン済み・ニックネームのみ）

```http
GET /rest/v1/public_profiles?id=eq.<user_id>&select=id,nickname,icon_key,avatar_path
Authorization: Bearer <token>
```

`public_profiles`はbio・child_age_rangeを含まない公開ビュー（[スキーマ定義](スキーマ定義.md)2節）。**未ログインは参照できない**（利用者IDを含むため）。対象は、自分自身と、公開中の投稿・コメントの投稿者に限る。未ログインが投稿者のニックネームを知るには、`public_posts`の`author_nickname`を使う。

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
- **保存前に、位置情報（GPS）などのメタデータを取り除く**。公開バケットの画像は誰でもダウンロードできるため、画像の構造を読み、描画に必要な部分だけを残した画像を保存する（EXIF・XMP・コメント・ICC・サムネイル・画像の終端より後ろに付け足されたデータは残らない。元のバイト列は保存しない）。JPEGの向き（Orientation）だけは、位置情報を持たない最小のEXIFとして残す。構造が壊れた画像・画像データのない画像は`422`。
- 保存前にOpenAI Moderationの画像判定で確認する（確認するのは、メタデータを除いた、実際に保存する画像）。不適切なら`422 MODERATION_REJECTED`、外部API障害なら`503 MODERATION_UNAVAILABLE`（保存しない）。確認の前に、利用者ごとのリクエスト上限（下の「レート制限」）を確かめる。
- 成功：`200`、`{ "avatar_path": "<user_id>/<id>.png" }`。公開URLはStorageの`avatars`バケットの公開URL＋`avatar_path`。差し替え時は旧画像を削除する。`DELETE`はアップロード画像を外してファイルを削除する。**プロフィールから外れた画像（差し替え・削除・イラストへの変更・退会）は、DBが同じトランザクションで「削除待ち」に記録する**ので、Storageの削除に失敗しても、成功するまで再試行される（公開URLに画像が残らない）。再試行の間隔は倍々に延び、失敗し続ける画像が後続を止めない。アップロードの**前**にも回収用の記録を残すので、結び付けが失敗しても、DBの障害が続いても、画像を取り残さない（記録できなければ、アップロードしない）。
- クライアントからStorageへ直接アップロードすることはできない。

### ニックネーム変更

```http
POST /functions/v1/profile-nickname
Authorization: Bearer <token>
{ "nickname": "あたらしい名前", "confirmed": false }
```

成功時`200`、旧名を`nickname_reservations`へ30日予約。初回の変更は制限なし、以降は前回の変更から30日空ける（違反は`422 VALIDATION_FAILED`）。旧名は他の人が30日使用できない（本人は再利用可）。送信前チェックあり。

### 退会（アカウント削除）

```http
POST /functions/v1/account-delete
Authorization: Bearer <token>
{ "confirm": true }
```

- **取消期間はなく、即時に削除する**。アプリ側で「元に戻せません」と確認してから呼ぶ。`confirm: true`がなければ`422`。
- **本人確認は、この操作に使うセッション自身が5分以内に作られていること**（`auth.sessions`の作成時刻）。ユーザー全体の最終ログイン時刻ではないので、本人が別の端末で再ログインしても、盗まれた古いセッションでは退会できない。古いセッションは`403`（`details.reason: "reauth_required"`）で、アプリは再ログインを求める。
- 運営者として登録されている間は`409`（`details.reason: "operator_registered"`）。先に登録を外す。
- 成功は`200 { "status": "deleted" }`。何度実行しても安全（途中で失敗した場合は、同じ操作を再実行する）。
- 削除されるもの・残るもの・期限は[退会とデータの保持](退会とデータの保持.md)。

## 3. 投稿

### 一覧取得（未ログイン可）

```http
GET /rest/v1/public_posts?select=id,post_type,topic_id,body,created_at,edited_at,comment_count,author_nickname,author_icon_key,author_avatar_path&order=created_at.desc,id.desc&limit=20
```

`public_posts`は一時非表示・削除済みを除外し、共感件数・通報情報・**投稿者の利用者ID（`author_id`）を含まない**公開ビュー（[権限表](権限表.md)2節）。投稿者の表示は`author_nickname`・`author_icon_key`・`author_avatar_path`。`edited_at`が非nullなら「編集済み」と表示する。`posts`テーブルは未ログインでは`author_id`を読めない（`select=*`も不可）。

### 検索・絞り込み・ページング（未ログイン可）

```http
POST /rest/v1/rpc/search_posts
{
  "p_query": "夜泣き 保育園",
  "p_post_type": "soudan",
  "p_topic_id": 1,
  "p_before_created_at": "2026-10-02T10:00:00Z",
  "p_before_id": "<前ページ最後のid>",
  "p_limit": 20
}
```

- 引数はすべて任意。`p_query`が空なら、条件に合う公開投稿の新着一覧になる（新着順の一覧は、これまでの`public_posts`・`feed_posts`でも取得できる）。
- 検索語は空白（全角を含む）で区切って**最大5語・全体で100文字まで**。全ての語を含む投稿を探す（AND）。全角・半角、英字の大文字・小文字を区別しない。1文字からでも検索できる。検索構文（`OR`・`-`・`列名:語`）は解釈されず、ただの文字として扱われる。
- 検索の対象は**投稿の本文のみ**（コメントの本文は混ざらない）。結果は**新着順のみ**（人気順・関連度順にしない）。
- ページングは`(created_at, id)`のキーセット。最後の行の`created_at`と`id`を、次の`p_before_created_at`・`p_before_id`に渡す（**両方を渡す**。片方だけは`400`）。同一時刻の投稿でも、重複・抜けがない。`p_limit`は1〜50（既定20、範囲外は丸める）。
- 戻りは`id`・`author_id`・`post_type`・`topic_id`・`body`・`reaction_mode`・`comment_acceptance`・`created_at`・`updated_at`・`edited_at`・`comment_count`・`author_nickname`・`author_icon_key`・`author_avatar_path`。**未ログインでは`author_id`は`null`**（利用者IDを出さない）。ログイン済みには、ブロック・通報のために返す。
- 未ログインは公開投稿のみ。ログイン済みは、個人の非表示・ブロック・話題と言葉のミュートが適用される（`feed_posts`と同じ）。一時非表示・削除済みの投稿は、どちらにも出ない。
- エラー：不正な投稿の種類、6語以上、101文字以上、カーソルの片方だけ、は`400`（PostgRESTの標準形式で`message`が`VALIDATION_FAILED`）。
- 方式の選定・実測は[検索方式の実測](検索方式の実測.md)。

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
{ "id": "b3c1...", "created_at": "2026-09-29T03:00:00Z", "support_notice": false }
```

送信前チェックで`MODERATION_CONFIRM_REQUIRED`が返る場合、クライアントは確認表示後に`{"...": "...", "confirmed": true}`を付けて再送する。`MODERATION_REJECTED`は`confirmed`を付けても覆らない。エラーの`details.reasons`には理由コード（`banned_word`・`pii_phone`・`harassment`等）だけを入れ、本文は含めない。

**設計案**：自分や子どもへの危害をほのめかす内容は投稿を止めず、書き込んだ本人へのレスポンスにだけ`"support_notice": true`を含め、クライアントが相談先を案内する。他の利用者へは公開しない（詳細は[送信前チェック評価](送信前チェック評価.md)）。

- 本文は前後の空白を除いて1文字以上、1,000文字まで（絵文字等は1文字）。`post_type`は`guchi`・`soudan`・`kotsu`、`reaction_mode`は省略すると`quiet_support`。`Idempotency-Key`は任意（同じキーの再送は最初の結果を返し、投稿を重複させない。利用者ごと・24時間）。
- 利用停止中・プロフィール未登録は`403 FORBIDDEN`（`details.reason`は`restricted`・`profile_required`）。

### 投稿の編集・削除（本人のみ）

```http
PATCH /functions/v1/posts/{id}
Authorization: Bearer <token>
{ "body": "書き直した内容", "confirmed": false }

DELETE /functions/v1/posts/{id}
Authorization: Bearer <token>
```

- 編集できるのは**本文のみ**（種類・話題・反応モードは変更できない）。編集後の本文も送信前チェックを通す。本文が実際に変わったときだけ`edited_at`が設定される（レスポンス`{ "id", "edited_at", "support_notice" }`）。利用停止中は編集できない（`403`）。
- 他人は`403 FORBIDDEN`、存在しなければ`404 NOT_FOUND`。
- 削除すると、コメント・返信・共感・保存・通知も一緒に消える（コメントした人への通知はしない）。成功は`200 { "deleted": true }`。

### 反応モード・受付状態の変更

```http
PATCH /functions/v1/posts/{id}/reaction-mode
Authorization: Bearer <token>
{ "reaction_mode": "want_comments", "comment_acceptance": "open" }
```

本人以外は`403 FORBIDDEN`。`reaction_mode`は`quiet_support`⇄`want_comments`の相互変更が可能。`comment_acceptance`は`want_comments`のときだけ`open`⇄`closed`を指定でき（省略すると現在の状態を保つ。`want_comments`への変更直後は`open`）、`quiet_support`に指定すると`422`。コメント保存とは投稿行のロックで直列化され、受付終了が確定した後に新規コメントが保存されることはない。

## 4. コメント・返信

### 一覧取得（ログイン必須）

```http
GET /rest/v1/member_comments?post_id=eq.<post_id>&select=id,author_id,parent_comment_id,body,is_deleted,created_at,edited_at,author_nickname,author_icon_key,author_avatar_path&order=created_at.asc
Authorization: Bearer <token>
```

`is_deleted`がtrueの行は`body`がnullで返る。クライアントは「削除済み」表示に置き換える。返信は`parent_comment_id`で親の下に表示する。一時非表示のコメント、および親投稿が一時非表示のコメントはRLSで除外される（運営者を除く）。`edited_at`が非nullなら「編集済み」。

### コメント・返信の作成

```http
POST /functions/v1/comments
Authorization: Bearer <token>
Idempotency-Key: <uuid>
{ "post_id": "b3c1...", "parent_comment_id": null, "body": "わかります、私も同じです" }
```

- 本文は前後の空白を除いて1文字以上、500文字まで（絵文字等は1文字）。`Idempotency-Key`は任意。
- 受付状態が`closed`・`quiet_support`の投稿、ブロックされている（投稿者、または返信先コメントの投稿者に）、利用停止中のいずれかであれば`403 FORBIDDEN`。`details.reason`は`comments_closed`・`restricted`・`unavailable`（ブロックされている場合。**ブロックを示す語は返さない**）。一時非表示の投稿・存在しない投稿は`404 NOT_FOUND`。
- 親コメントが返信（返信への返信）、別の投稿のコメント、存在しない、削除済み、一時非表示の場合は`422 VALIDATION_FAILED`。
- 成功は`201 { "id", "created_at", "support_notice" }`。投稿者（返信なら返信先コメントの投稿者）へ通知が作られる（自分自身へは通知しない）。

### コメント編集・削除

```http
PATCH /functions/v1/comments/{id}
Authorization: Bearer <token>
{ "body": "書き直した内容" }

DELETE /functions/v1/comments/{id}
Authorization: Bearer <token>
```

編集は本人のみ・**受付終了後も可**で、送信前チェックを通す。本文が変わったときだけ`edited_at`が設定される。利用停止中は編集できない。削除は`deleted_at`を設定するソフト削除（[スキーマ定義](スキーマ定義.md)3節）で、本文は消えて返信は残る。他人は`403`、削除済みは`404`。成功は`200`。

## 5. リアクション

```http
PUT /functions/v1/posts/{id}/reaction
Authorization: Bearer <token>
{ "reaction_type_id": 3 }

DELETE /functions/v1/posts/{id}/reaction
Authorization: Bearer <token>
```

- `PUT`は登録・選び直しを1操作で扱う（`on conflict do update`。1投稿1人1つ、同時に操作しても1件に保たれる）。成功は`200 { "post_id", "reaction_type_id", "updated_at" }`。コメント受付が終了していても共感できる。
- `DELETE`は取消。常に成功し（`200 { "deleted": true|false }`）、投稿の存在を知る手がかりにならない。
- `PUT`のエラー：未ログイン`401`、定型文が存在しない・無効`422`、見えない投稿（一時非表示・削除済み・存在しない）`404`、ブロックされている・利用停止中・プロフィール未登録・**自分の投稿**は`403`（`details.reason`は`unavailable`（ブロックされている場合）・`restricted`・`profile_required`・`not_owner`）。自分の投稿への共感は暫定で不可（未決事項）。
- 共感は`reactions`テーブルへ**直接書き込めない**（ブロック・利用停止・非表示の確認を迂回できないため、DB関数に一本化した）。自分の共感は`GET /rest/v1/reactions?post_id=eq.<id>`で参照できる。
- 件数は`reactions`テーブルへの直接SELECTでは取得できない（他者の行が見えてしまうため）。投稿者本人と運営者のみ以下のRPC（`security definer`関数）で取得する（運営者にも共感の行そのものは見せない）（[スキーマ定義](スキーマ定義.md)4節）：

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
GET    /rest/v1/saved_post_list?select=*&order=saved_at.desc&limit=20
POST   /rest/v1/hidden_items       { "target_type": "post", "target_id": "..." }
POST   /rest/v1/blocks             { "blocked_id": "..." }
DELETE /rest/v1/blocks?blocked_id=eq.<id>
POST   /rest/v1/muted_topics       { "topic_id": 3 }
POST   /rest/v1/muted_words        { "word": "..." }
```

保存一覧（`saved_post_list`）は本人だけが取得でき、投稿の列に`saved_at`が付く。見えなくなった投稿（削除・一時非表示・ブロック・自分だけの非表示）は一覧に出ない（保存自体は残る）。**見えない投稿・存在しない投稿は保存できず、どちらも`42501`で、投稿の存在を知る手がかりにならない**。保存数・保存した事実は誰にも公開せず、通知もしない。共感・保存で投稿者へ通知は作られない（共感のまとめ通知は#19）。

いずれもRLSで本人の行のみ操作可能（[権限表](権限表.md)5節）。PostgRESTの一意制約違反は`409`（PostgRESTの標準応答）として返る。重複操作を許したい場合は`Prefer: resolution=ignore-duplicates`を付ける。解除（`DELETE`）は、対象がなくてもエラーにならない（冪等）。自分自身のブロックは`400`（CHECK制約）。ブロックされた相手には通知せず、ブロックされている事実を参照する経路もない。

### 取得への反映（ログイン済み）

ブロック・自分だけの非表示は、クライアントの絞り込み任せではなく、**サーバー（ビュー）が強制して除外する**。ミュートは一覧・検索にだけ適用する。

| 取得経路 | ビュー | ブロック | 自分だけの非表示 | 話題・言葉のミュート |
|---|---|---|---|---|
| 投稿の一覧・検索 | `feed_posts` | 除外 | 除外 | 除外 |
| 投稿の詳細（ID指定） | `member_posts` | 除外 | 除外 | 適用しない |
| コメント・返信の一覧 | `member_comments` | 除外 | 除外 | 適用しない |
| お知らせ（通知） | `notifications` | ブロックした相手が起こした通知は除外 | ― | ― |
| 未ログインの一覧（`public_posts`） | ― | 個人の設定がないため適用なし | 同左 | 同左 |

- `feed_posts`・`member_posts`は、一覧に必要な列（`author_id`・`author_nickname`・`comment_count`・`edited_at`など）を持つ。ログイン済みはブロック・通報のために`author_id`を取得できる。未ログインは参照できない。
- 言葉のミュートは、全角・半角と英字の大文字小文字を区別しない部分一致（NFKC＋小文字化）。投稿の本文にだけ適用し、コメントには適用しない。一覧の件数（`comment_count`）は、ブロックした相手のコメントを含む。
- 上限（暫定）：ミュートする言葉は100件・1語100文字まで。超えるとエラー（`54000`、メッセージ`LIMIT_EXCEEDED`）。前後の空白は除いて保存し、空白のみは不可。
- ブロックされた側からは、ブロックした人の公開投稿は引き続き見える（公開のため完全には隠さない）。コメント・返信・共感は、サーバーが`403 FORBIDDEN`で拒否する。**ブロックしたことは相手に知らせない**ため、レスポンスの理由は汎用の`unavailable`で、ブロックを示す語を含めない。クライアントは、ブロックの有無を知る手段がないので、通常と同じ入力欄の表示のまま、失敗時は汎用のエラーを表示する（Notionの受入条件案「ブロックを推測させない表示」）。直接APIを叩く人には、拒否されたことまでは分かる。

## 7. 通報・運営

### 通報

```http
POST /functions/v1/reports
Authorization: Bearer <token>
{ "target_type": "post", "target_id": "...", "reason": "personal_info", "detail": "" }
```

- `reason`は6種：`harassment`（誹謗中傷・攻撃的）・`personal_info`（名前や個人情報）・`spam`（勧誘・宣伝・スパム）・`copyright`（他人の文章や画像の転載）・`danger`（危険を感じる内容。自分や子どもを傷つけそうなど）・`other`（その他）。`detail`は任意で200文字まで（「その他」は一言添えられる）。
- 成功は`201 { "id", "duplicate": false }`。**同じ人が同じ対象を通報し直した場合は、件数が増えず`200 { "id", "duplicate": true }`**（最初の理由は書き換えない）。同時に通報しても1件。
- 通報できるのは、自分に見える投稿・コメントで、自分のものではないもの。存在しない・一時非表示・削除済みは、どれも`404 NOT_FOUND`（存在を知る手がかりにしない）。自分の投稿・コメントは`403`（`details.reason: "not_allowed"`）。利用停止中・プロフィール未登録は`403`（`restricted`・`profile_required`）。
- **ブロック関係があっても通報はできる**（通報は運営へ届くもので、相手には届かない。権限表の記述を、安全のためこう解釈した。未決事項）。
- 異なる3人の通報で、投稿・コメントが自動で一時非表示になる（同時に3人が通報しても取りこぼさない）。**再表示のあとに再び3人が通報しても、自動では再び非表示にならず**、運営の確認対象として残る。
- **通報者の情報は、通報された側にもほかの利用者にも出ない**。通報（`reports`）を参照できるのは、通報した本人と運営者（二段階認証済み）だけ。
- 通報は直接書き込めない（Edge Function経由のみ）。

### 一時非表示中の表示（本人へ「確認中」）

```http
GET /rest/v1/my_posts?select=*&order=created_at.desc&limit=20
GET /rest/v1/member_comments?post_id=eq.<post_id>&select=*,under_review
```

- 一時非表示の投稿は、投稿者本人にだけ`my_posts`で`under_review: true`（確認中）として見える。ほかの人には、一覧・検索・詳細のどこにも出ない（投稿者本人にも、一覧・検索には出ない）。
- 一時非表示のコメントも、投稿者本人にだけ`member_comments`で`under_review: true`として見える。

### 運営の通報一覧（運営者専用）

```http
GET /rest/v1/admin_report_queue?select=*&order=is_hidden.desc,last_reported_at.desc
Authorization: Bearer <二段階認証済みのトークン>
```

対象（投稿・コメント）ごとに、未対応の通報を`report_count`（通報者の数）・`reasons`・`first_reported_at`・`last_reported_at`・`is_hidden`・`target_owner_id`・`body`でまとめる。一時非表示中のものを先に並べるには、`is_hidden.desc`を指定する。**運営者（`admin_users`登録済み、かつ`aal2`）でなければ、0件が返る**。個別の通報（通報者のID・補足）は、`reports`テーブルを同じ条件で参照する。

### 運営の対処（運営者専用）

```http
POST /functions/v1/moderation/actions
Authorization: Bearer <二段階認証済みのトークン>
{ "target_type": "post", "target_id": "...", "action": "unhide", "reason": "誤検知のため再表示" }
```

| `action` | `target_type` | `reason` | 内容 |
|---|---|---|---|
| `unhide` | `post`・`comment` | 任意 | 一時非表示を解除し、対象の未対応の通報をまとめて対応済みにする。本人へは通知しない |
| `delete` | `post`・`comment` | **必須** | 投稿は削除、コメントは本文が消えるソフト削除。未対応の通報は対応済みになる。**本人へ通知し、理由を読める** |
| `warn` | `user` | **必須** | 警告（本人へ通知。理由を読める） |
| `suspend` | `user` | **必須** | 利用停止（本人へ通知）。段階は、早期解除されていない過去の制限の件数で決まる：初回7日→再発30日→再発以降は無期限。**停止中の利用者のセッションを取り消す**（再ログインが必要。再ログインはできるが、書き込みは`restricted`で拒否される）。すでに停止中なら`409 CONFLICT`（段階を二重に進めない） |
| `guide` | `user` | 任意 | 相談先の案内（本人へ通知）。「危険を感じる内容」の通報への対応に使う。案内の内容（電話・URL・文言）は未決定で、アプリ側のページで持つ |

- 成功は`200 { "id", "action", "restriction_stage" }`（`restriction_stage`は`suspend`のときだけ）。
- **運営者として登録されていない利用者には、この機能の存在を明かさない（`404`）。登録されていても、二段階認証（`aal2`）を済ませていないセッションは`403`（`details.reason: "mfa_required"`）**。運営者のIDはトークンから取り、リクエスト本文のIDは使わない。運営者自身には`warn`・`suspend`をかけられない（`403`）。
- 警告・利用停止・相談先案内の対象は利用者（`user`）。通報一覧の`target_owner_id`を使う。
- 本人へのお知らせは`notifications`（`notification_type: "moderation"`、`moderation_action_id`）で届き、対処の理由は`moderation_actions`から本人が読める（**通報者の情報は含まれない**）。
- すべての対処は`moderation_actions`に記録される（誰が・いつ・何を・理由）。
- 設定の手順・検証は[運営の二段階認証](運営の二段階認証.md)。

### 運営設定（運営者専用）

```http
GET /functions/v1/moderation/settings
PUT /functions/v1/moderation/settings
Authorization: Bearer <二段階認証済みのトークン>
{ "key": "new_signup_halted", "value": true }
{ "key": "new_user_limit", "value": { "enabled": true, "window_hours": 24, "max_posts": 1, "max_comments": 3 } }
```

- `GET`は`200 { "settings": { "new_user_limit": ..., "new_signup_halted": ... } }`。`PUT`も更新後の`settings`を返す。
- 変えられるキーは`new_user_limit`・`new_signup_halted`だけ（それ以外は`422`）。値の形・範囲の違反も`422`。変更の履歴（誰が・いつ・前の値・新しい値）が残る。
- 認証の扱いは運営の対処と同じ：運営者でなければ`404`、`aal2`でなければ`403`（`mfa_required`）。

### レート制限・新規登録停止のエラー

- **外部API（送信前チェック）を呼ぶ前に、必ず確認する**（`preflight_write`）。順番は、(1) 操作の資格（利用停止中・プロフィール未登録）、(2) 登録直後の上限（作成のみ。数えずに判定）、(3) 利用者ごとのリクエスト上限。(1)(2)で止まった要求は、外部APIを呼ばず、(3)の回数にも数えない。完了済みの`Idempotency-Key`の再送は、(2)の対象にしない（最初の結果を返せる）。
- **利用者ごとのリクエスト上限（暫定）**：送信前チェックを呼ぶ操作（投稿・コメント・編集・プロフィール系）は10分に30回、画像は10分に10回。超えると`429 RATE_LIMITED`（`details.reason: "request_limit"`、`retry_at`）。登録直後の上限は`reason: "new_user_limit"`。

- 登録直後の投稿・コメントが上限を超えると`429 RATE_LIMITED`（`details.reason: "new_user_limit"`、`details.retry_at`：制限が解ける日時）。再送（同じIdempotency-Key）は数えない。拒否された試行も数えない。
- 新規登録の停止中、`profile-create`は新しいプロフィールを`429 RATE_LIMITED`（`details.reason: "signup_halted"`）で拒否する。アカウントの作成自体は、Authのフックが拒否する（メール・Google・Appleに共通。`429`、メッセージは「現在、新規登録を一時的にお休みしています」）。**既存の利用者のログインと、公開の閲覧は止めない**。

## 8. 通知

```http
GET   /rest/v1/notifications?select=*&order=created_at.desc&limit=20
Authorization: Bearer <token>

PATCH /rest/v1/notifications?id=eq.<id>          { "is_read": true }
PATCH /rest/v1/notification_settings?user_id=eq.<自分> { "comments_enabled": false }   -- replies_enabled / reactions_enabled / push_enabled も同様
POST  /rest/v1/rpc/register_push_device           { "p_platform": "ios", "p_token": "<FCMのトークン>" }
DELETE /rest/v1/push_devices?device_token=eq.<トークン>   -- ログアウト時の解除
```

- **通知を読める・既読にできるのは、受信者本人だけ**。既読の更新は`is_read`だけ（宛先などは書き換えられない）。ブロックした相手が起こした通知は表示されない。未読の件数は`?is_read=eq.false`と`Prefer: count=exact`で取る。
- 通知の種類：`comment`（自分の投稿へのコメント）・`reply`（自分のコメントへの返信）・`reaction_digest`（共感のまとめ。`reaction_count`）・`moderation`（運営からのお知らせ）。**共感のまとめ通知は、誰が共感したかを持たない**。
- 共感のまとめ通知は、毎朝7時（日本時間）に、前回以降の共感を投稿者ごとに1通にして作る。自分の共感・ブロックした相手の共感・一時非表示の投稿への共感は数えない。
- 通知の設定を止めた種類は、通知自体が作られない。`push_enabled`を止めた場合は、アプリ内の通知は作られ、プッシュだけ送られない。運営からのお知らせは止められない。
- **端末の登録は`register_push_device`だけ**（直接のINSERT/UPDATEは拒否される）。同じ端末で別の人がログインしたら、持ち主が新しい人に移り、前の人宛ての未送信のプッシュは届かない。
- **プッシュの文面は定型文だけ**（「あなたの投稿にコメントが届きました」など）。投稿・コメントの本文、相手のニックネーム、共感の数は含めない。プッシュの`data`には、種類（`type`）と通知ID（`notification_id`）だけを入れる。アプリが開いたときに、通知IDから取得して表示する。

### プッシュの配信（内部用）

`POST /functions/v1/push-dispatch`（ヘッダー`x-job-secret`）。配信キューを取り出してFCMへ送る。**定期実行から呼ぶ内部用で、アプリからは呼ばない**。秘密がない・違う・未設定のときは`404`（存在を明かさない）、FCMの認証情報が未設定なら`503`。応答は`{ claimed, sent, retry, invalid_token, record_failed }`。失敗は1・5・25・125分後に再試行し、5回で打ち切る。無効な端末は削除される。

## 9. 本書の対象外・今後確定する事項

- 具体的な関数名・URLパス、OpenAPI／型定義生成の方式は#11〜#13で確定する。
- 認証（サインアップ・ログイン・OAuth）のエンドポイントはSupabase Auth標準APIを利用し、本書では扱わない。
- レート制限（`RATE_LIMITED`）の閾値は`app_settings`の値に従う（7節の設定API）。初期値は暫定（[未決事項](未決事項.md)）。
- 日本語検索のクエリ形式は方式未確定のため、一覧APIの`q`パラメータ等は#16で追加する。

## 参照

- [スキーマ定義](スキーマ定義.md)
- [権限表](権限表.md)
- [バックエンド設計](バックエンド設計.md)
- [未決事項](未決事項.md)
