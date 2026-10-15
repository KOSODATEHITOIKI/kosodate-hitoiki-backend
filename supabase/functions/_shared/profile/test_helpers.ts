import { type ModerationScores, ModerationUnavailableError } from "../moderation/types.ts";
import { DbError, type ProfileDb, type ProfileDeps } from "./types.ts";

export const USER_ID = "00000000-0000-0000-0000-0000000000a1";

export interface Fake {
  deps: ProfileDeps;
  calls: {
    createProfile: Parameters<ProfileDb["createProfile"]>[0][];
    changeNickname: string[];
    updateProfile: Parameters<ProfileDb["updateProfile"]>[1][];
    setAvatarPath: (string | null)[];
    uploaded: string[];
    removed: string[];
    moderated: string[];
    moderatedImages: number;
    preflight: string[];
    finishedDeletions: { path: string; ok: boolean }[];
    reserved: string[];
    /** 画像のチェック（外部API）に渡された画像のバイト列。 */
    imagesChecked: Uint8Array[];
    /** Storageへアップロードされた画像のバイト列。 */
    uploadedBytes: Uint8Array[];
  };
  state: { avatarPath: string | null; pendingDeletions: string[]; reserved: string[] };
}

export function makeFake(options: {
  loggedIn?: boolean;
  scores?: ModerationScores;
  imageScores?: ModerationScores;
  moderationDown?: boolean;
  createResult?: "created" | "exists" | "conflict";
  dbError?: DbError;
  setAvatarError?: DbError;
  avatarPath?: string | null;
  /** 外部API前の確認（preflight）が返すエラー。 */
  preflightError?: DbError;
  /** Storageの削除が失敗する。 */
  removeFails?: boolean;
  /** アップロード前の回収用の記録（reserve）が失敗する（DBの障害）。 */
  reserveFails?: boolean;
} = {}): Fake {
  const fake: Fake = {
    calls: {
      createProfile: [],
      changeNickname: [],
      updateProfile: [],
      setAvatarPath: [],
      uploaded: [],
      removed: [],
      moderated: [],
      moderatedImages: 0,
      preflight: [],
      finishedDeletions: [],
      reserved: [],
      imagesChecked: [],
      uploadedBytes: [],
    },
    state: { avatarPath: options.avatarPath ?? null, pendingDeletions: [], reserved: [] },
    deps: undefined as unknown as ProfileDeps,
  };
  const maybeFail = () => {
    if (options.dbError) throw options.dbError;
  };

  fake.deps = {
    authenticate: () => Promise.resolve(options.loggedIn === false ? null : USER_ID),
    moderation: {
      moderate: (text) => {
        fake.calls.moderated.push(text);
        return options.moderationDown
          ? Promise.reject(new ModerationUnavailableError())
          : Promise.resolve(options.scores ?? {});
      },
    },
    imageModeration: {
      moderateImage: (bytes) => {
        fake.calls.moderatedImages++;
        fake.calls.imagesChecked.push(bytes);
        return options.moderationDown
          ? Promise.reject(new ModerationUnavailableError())
          : Promise.resolve(options.imageScores ?? {});
      },
    },
    db: {
      preflight: (_u, kind) => {
        fake.calls.preflight.push(kind);
        if (options.preflightError) throw options.preflightError;
        return Promise.resolve();
      },
      claimStorageDeletions: () => Promise.resolve([...fake.state.pendingDeletions]),
      finishStorageDeletion: (path, ok) => {
        fake.calls.finishedDeletions.push({ path, ok });
        if (ok) fake.state.pendingDeletions = fake.state.pendingDeletions.filter((p) => p !== path);
        return Promise.resolve();
      },
      reserveStorageUpload: (path) => {
        if (options.reserveFails) return Promise.reject(new DbError("XX000"));
        fake.calls.reserved.push(path);
        fake.state.reserved.push(path);
        return Promise.resolve();
      },
      createProfile: (args) => {
        maybeFail();
        fake.calls.createProfile.push(args);
        return Promise.resolve(options.createResult ?? "created");
      },
      changeNickname: (_userId, nickname) => {
        maybeFail();
        fake.calls.changeNickname.push(nickname);
        return Promise.resolve();
      },
      updateProfile: (_userId, patch) => {
        maybeFail();
        fake.calls.updateProfile.push(patch);
        // 本番ではDBのトリガーが行う：イラストを選ぶとアップロード画像が外れ、旧画像が削除待ちに記録される
        if (patch.icon_key && fake.state.avatarPath) {
          fake.state.pendingDeletions.push(fake.state.avatarPath);
          fake.state.avatarPath = null;
        }
        return Promise.resolve();
      },
      getAvatarPath: () => Promise.resolve(fake.state.avatarPath),
      setAvatarPath: (_userId, path) => {
        if (options.setAvatarError) throw options.setAvatarError;
        fake.calls.setAvatarPath.push(path);
        // 本番ではDBのトリガーが行う：プロフィールから外れた旧画像を削除待ちに記録する
        if (fake.state.avatarPath && fake.state.avatarPath !== path) {
          fake.state.pendingDeletions.push(fake.state.avatarPath);
        }
        fake.state.avatarPath = path;
        // 本番ではDBが同じトランザクションで、結び付けた画像の回収用の記録を消す
        if (path) fake.state.reserved = fake.state.reserved.filter((p) => p !== path);
        return Promise.resolve();
      },
    },
    storage: {
      upload: (path, bytes) => {
        fake.calls.uploaded.push(path);
        fake.calls.uploadedBytes.push(bytes);
        return Promise.resolve();
      },
      remove: (path) => {
        if (options.removeFails) return Promise.reject(new DbError("STORAGE"));
        fake.calls.removed.push(path);
        return Promise.resolve();
      },
    },
    newId: () => "fixed-id",
  };
  return fake;
}

export function jsonRequest(method: string, body: unknown): Request {
  return new Request("http://localhost/fn", {
    method,
    headers: { "Content-Type": "application/json", Authorization: "Bearer token" },
    body: JSON.stringify(body),
  });
}

export function imageRequest(method: string, bytes: Uint8Array, contentType: string): Request {
  return new Request("http://localhost/fn", {
    method,
    headers: { "Content-Type": contentType, Authorization: "Bearer token" },
    body: bytes as BodyInit,
  });
}

/** テスト用の、構造が正しい最小の画像（メタデータの除去を通る）。 */
const u32be = (n: number) => [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];
const pngChunk = (type: string, data: number[]) => [
  ...u32be(data.length),
  ...[...type].map((c) => c.charCodeAt(0)),
  ...data,
  0,
  0,
  0,
  0,
];
export const PNG = new Uint8Array([
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  ...pngChunk("IHDR", new Array(13).fill(0)),
  ...pngChunk("IDAT", [1, 2, 3]),
  ...pngChunk("IEND", []),
]);
export const JPEG = new Uint8Array([
  0xff,
  0xd8,
  0xff,
  0xdb,
  0x00,
  0x04,
  1,
  1, // DQT
  0xff,
  0xc0,
  0x00,
  0x0b,
  8,
  0,
  8,
  0,
  8,
  1,
  1,
  0x11,
  0, // SOF0
  0xff,
  0xda,
  0x00,
  0x08,
  1,
  1,
  0,
  0,
  0x3f,
  0, // SOS
  1,
  2,
  3,
  0xff,
  0xd9,
]);
/** GPSと文字列を含むEXIFつきのJPEG（メタデータの除去の確認用）。 */
const GPS_PAYLOAD = [..."Exif\0\0GPSLatitude=35.6N"].map((c) => c.charCodeAt(0));
export const JPEG_WITH_GPS = new Uint8Array([
  0xff,
  0xd8,
  0xff,
  0xe1,
  0x00,
  GPS_PAYLOAD.length + 2,
  ...GPS_PAYLOAD,
  ...JPEG.subarray(2),
]);
