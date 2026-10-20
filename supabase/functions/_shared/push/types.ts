import type { JobSecretVerifier } from "../internal_auth.ts";

/** プッシュの配信（FCM）。DBの配信キュー（push_deliveries）を取り出して送る。 */
export type PushOutcome = "sent" | "retry" | "invalid_token";

export interface PushJob {
  deliveryId: string;
  notificationId: string;
  notificationType: string;
  platform: string;
  deviceToken: string;
}

export interface PushDb {
  /** 送る分を取り出す（取り出した分は一定時間ロックされる）。 */
  claim(limit: number): Promise<PushJob[]>;
  /** 結果を記録する。errorCode は英数字・アンダースコアのコードだけ（本文・トークンは入れない）。 */
  finish(deliveryId: string, outcome: PushOutcome, errorCode?: string): Promise<void>;
}

export interface PushSender {
  send(job: PushJob): Promise<{ outcome: PushOutcome; errorCode?: string }>;
}

export interface PushDeps {
  db: PushDb;
  sender: PushSender;
  /** 受け取った秘密が正しいかを、DB（Vault）に問い合わせて確かめる。未登録なら、誰も起動できない。 */
  verifyJobSecret: JobSecretVerifier;
  /** FCMの認証情報が設定されているか。 */
  senderConfigured: boolean;
}
