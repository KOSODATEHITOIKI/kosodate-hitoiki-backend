import { assertEquals, assertRejects } from "@std/assert";
import { responseForDecision, responseForError } from "./http.ts";
import { moderateAndSave } from "./moderate_and_save.ts";
import { type ModerationScores, ModerationUnavailableError } from "./types.ts";

const ok = (scores: ModerationScores = {}) => ({ moderate: () => Promise.resolve(scores) });

Deno.test("allow のときだけ保存し、保存にはチェックした本文をそのまま渡す", async () => {
  const body = "今日は大変だった";
  let saved: unknown;
  const r = await moderateAndSave({ body }, ok(), {}, (v) => {
    saved = v;
    return Promise.resolve("id-1");
  });
  assertEquals(r.result.decision, "allow");
  assertEquals(r.saved, "id-1");
  assertEquals(saved, { body });
});

Deno.test("保存に渡す値は凍結されており、書き換えられない", async () => {
  await moderateAndSave({ body: "こんにちは" }, ok(), {}, (v) => {
    let threw = false;
    try {
      (v as Record<string, string>).body = "書き換え";
    } catch {
      threw = true;
    }
    assertEquals(threw, true);
    assertEquals(v.body, "こんにちは");
    return Promise.resolve(null);
  });
});

Deno.test("呼び出し元が後から元のオブジェクトを書き換えても、保存されるのはチェック時点の本文", async () => {
  const fields: Record<string, string> = { body: "チェックした本文" };
  let stored = "";
  await moderateAndSave(
    fields,
    {
      moderate: () => {
        fields.body = "すり替えた本文";
        return Promise.resolve({});
      },
    },
    {},
    (v) => {
      stored = v.body;
      return Promise.resolve(null);
    },
  );
  assertEquals(stored, "チェックした本文");
});

Deno.test("reject / confirm のときは保存しない", async () => {
  let called = 0;
  const save = () => {
    called++;
    return Promise.resolve(null);
  };
  const rejected = await moderateAndSave({ body: "お前は死ね" }, ok(), {}, save);
  const confirm = await moderateAndSave(
    { body: "あの人ひどい" },
    ok({ harassment: 0.6 }),
    {},
    save,
  );
  assertEquals([rejected.result.decision, confirm.result.decision], ["reject", "confirm"]);
  assertEquals(called, 0);
});

Deno.test("confirmed=true で境界域は保存できる", async () => {
  const r = await moderateAndSave({ body: "あの人ひどい" }, ok({ harassment: 0.6 }), {
    confirmed: true,
  }, () => Promise.resolve("id-2"));
  assertEquals(r.saved, "id-2");
});

Deno.test("複数フィールド：1つでも reject なら全体を保存しない", async () => {
  let called = 0;
  const r = await moderateAndSave(
    { nickname: "たろう", bio: "連絡は090-1234-5678まで" },
    ok(),
    {},
    () => {
      called++;
      return Promise.resolve(null);
    },
  );
  assertEquals(r.result.decision, "reject");
  assertEquals(r.result.reasons, ["pii_phone"]);
  assertEquals(called, 0);
});

Deno.test("外部API障害：保存せず例外を伝える", async () => {
  let called = 0;
  await assertRejects(
    () =>
      moderateAndSave(
        { body: "こんにちは" },
        {
          moderate: () => Promise.reject(new ModerationUnavailableError()),
        },
        {},
        () => {
          called++;
          return Promise.resolve(null);
        },
      ),
    ModerationUnavailableError,
  );
  assertEquals(called, 0);
});

Deno.test("危害のほのめかし：保存を許可し、supportNotice を返す", async () => {
  const r = await moderateAndSave(
    { body: "もう消えたい" },
    ok({ "self-harm": 0.9 }),
    {},
    () => Promise.resolve("id-3"),
  );
  assertEquals(r.saved, "id-3");
  assertEquals(r.result.supportNotice, true);
});

Deno.test("HTTPレスポンス：API契約のコードとステータスに対応する", async () => {
  const reject = responseForDecision({
    decision: "reject",
    reasons: ["banned_word"],
    supportNotice: false,
  })!;
  const confirm = responseForDecision({
    decision: "confirm",
    reasons: ["harassment"],
    supportNotice: false,
  })!;
  const unavailable = responseForError(new ModerationUnavailableError())!;
  assertEquals([reject.status, confirm.status, unavailable.status], [422, 409, 503]);
  assertEquals((await reject.json()).error.code, "MODERATION_REJECTED");
  assertEquals((await confirm.json()).error.code, "MODERATION_CONFIRM_REQUIRED");
  assertEquals((await unavailable.json()).error.code, "MODERATION_UNAVAILABLE");
  assertEquals(responseForDecision({ decision: "allow", reasons: [], supportNotice: false }), null);
  assertEquals(responseForError(new Error("other")), null);
});

Deno.test("複数フィールド：後ろのフィールドの個人情報は、外部API障害より先に reject される", async () => {
  const calls: string[] = [];
  const r = await moderateAndSave(
    { nickname: "たろう", bio: "連絡は090-1234-5678まで" },
    {
      moderate: (text) => {
        calls.push(text);
        return Promise.reject(new ModerationUnavailableError());
      },
    },
    {},
    () => Promise.resolve(null),
  );
  assertEquals(r.result.decision, "reject");
  assertEquals(r.result.reasons, ["pii_phone"]);
  assertEquals(calls, []); // どのフィールドも外部APIへ送らない
});
