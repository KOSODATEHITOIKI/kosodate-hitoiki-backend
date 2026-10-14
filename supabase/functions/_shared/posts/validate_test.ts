import { assertEquals } from "@std/assert";
import {
  validateAcceptance,
  validateCommentBody,
  validateIdempotencyKey,
  validatePostBody,
  validatePostType,
  validateReactionMode,
  validateTopicId,
  validateUuid,
} from "./validate.ts";

const FAMILY = "👨‍👩‍👧‍👦"; // 1つの絵文字だが、コードポイントは7つ

Deno.test("投稿：1,000文字まで（境界）。絵文字は1文字として数える", () => {
  assertEquals(validatePostBody("あ".repeat(1000)).ok, true);
  assertEquals(validatePostBody("あ".repeat(1001)).ok, false);
  assertEquals(validatePostBody(FAMILY.repeat(1000)).ok, true); // コードポイントでは7,000
  assertEquals(validatePostBody(FAMILY.repeat(1001)).ok, false);
});

Deno.test("コメント：500文字まで（境界）。絵文字は1文字として数える", () => {
  assertEquals(validateCommentBody("あ".repeat(500)).ok, true);
  assertEquals(validateCommentBody("あ".repeat(501)).ok, false);
  assertEquals(validateCommentBody(FAMILY.repeat(500)).ok, true);
  assertEquals(validateCommentBody(FAMILY.repeat(501)).ok, false);
});

Deno.test("本文：空・空白のみ・型違いは不可。前後の空白は除いて保存", () => {
  for (const input of ["", "   ", "\n\t ", "　", 5, null, undefined, {}]) {
    assertEquals(validatePostBody(input).ok, false, String(input));
    assertEquals(validateCommentBody(input).ok, false, String(input));
  }
  assertEquals(validatePostBody("  こんにちは \n"), { ok: true, value: "こんにちは" });
});

Deno.test("本文：途中の改行・空白は保つ", () => {
  assertEquals(validatePostBody("一行目\n\n二行目"), { ok: true, value: "一行目\n\n二行目" });
});

Deno.test("投稿の種類・反応モード・受付状態・話題", () => {
  assertEquals(validatePostType("guchi").ok, true);
  assertEquals(validatePostType("kotsu").ok, true);
  assertEquals(validatePostType("other").ok, false);
  assertEquals(validatePostType(undefined).ok, false);
  assertEquals(validateReactionMode("quiet_support").ok, true);
  assertEquals(validateReactionMode("want_comments").ok, true);
  assertEquals(validateReactionMode("x").ok, false);
  assertEquals(validateAcceptance(undefined), { ok: true, value: null });
  assertEquals(validateAcceptance("closed"), { ok: true, value: "closed" });
  assertEquals(validateAcceptance("x").ok, false);
  assertEquals(validateTopicId(undefined), { ok: true, value: null });
  assertEquals(validateTopicId(3), { ok: true, value: 3 });
  for (const bad of [0, -1, 1.5, "3", 40000, NaN]) {
    assertEquals(validateTopicId(bad).ok, false, String(bad));
  }
});

Deno.test("IDとIdempotency-Keyの形式", () => {
  assertEquals(validateUuid("00000000-0000-0000-0000-0000000000b1", "id").ok, true);
  for (const bad of ["x", "", 5, null, "00000000-0000-0000-0000-0000000000b1; drop table"]) {
    assertEquals(validateUuid(bad, "id").ok, false, String(bad));
  }
  assertEquals(validateIdempotencyKey(null), { ok: true, value: null });
  assertEquals(validateIdempotencyKey("3f2c-uuid_1"), { ok: true, value: "3f2c-uuid_1" });
  assertEquals(validateIdempotencyKey("a".repeat(65)).ok, false);
  assertEquals(validateIdempotencyKey("bad key!").ok, false);
});
