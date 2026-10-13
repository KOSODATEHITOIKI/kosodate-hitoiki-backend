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
  };
  state: { avatarPath: string | null };
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
    },
    state: { avatarPath: options.avatarPath ?? null },
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
      moderateImage: () => {
        fake.calls.moderatedImages++;
        return options.moderationDown
          ? Promise.reject(new ModerationUnavailableError())
          : Promise.resolve(options.imageScores ?? {});
      },
    },
    db: {
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
        return Promise.resolve();
      },
      getAvatarPath: () => Promise.resolve(fake.state.avatarPath),
      setAvatarPath: (_userId, path) => {
        if (options.setAvatarError) throw options.setAvatarError;
        fake.calls.setAvatarPath.push(path);
        fake.state.avatarPath = path;
        return Promise.resolve();
      },
    },
    storage: {
      upload: (path) => {
        fake.calls.uploaded.push(path);
        return Promise.resolve();
      },
      remove: (path) => {
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

export const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
export const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
