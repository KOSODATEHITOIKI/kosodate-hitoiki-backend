/**
 * プッシュ通知の文面。投稿・コメントの本文、相手のニックネーム、共感の数は含めない（決定済み）。
 * ロック画面を周りの人に見られても、悩みの内容や誰とのやりとりかが分からないようにするため。
 */
export function pushMessage(notificationType: string): { title: string; body: string } {
  switch (notificationType) {
    case "comment":
      return { title: "お知らせ", body: "あなたの投稿にコメントが届きました" };
    case "reply":
      return { title: "お知らせ", body: "あなたのコメントに返信が届きました" };
    case "reaction_digest":
      return { title: "お知らせ", body: "あなたの投稿に共感が届きました" };
    case "moderation":
      return { title: "お知らせ", body: "運営からのお知らせがあります" };
    default:
      return { title: "お知らせ", body: "新しいお知らせがあります" };
  }
}
