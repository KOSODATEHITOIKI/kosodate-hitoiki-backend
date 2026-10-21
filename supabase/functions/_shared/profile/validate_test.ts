import { assertEquals } from "@std/assert";
import {
  graphemeCount,
  validateBio,
  validateChildAgeRange,
  validateIconKey,
  validateNickname,
  validateTermsVersion,
} from "./validate.ts";

const FAMILY = "👨‍👩‍👧‍👦"; // 1つの絵文字だが、コードポイントは7つ

Deno.test("書記素：絵文字・結合文字は見た目の1文字として数える", () => {
  assertEquals(graphemeCount(FAMILY), 1);
  assertEquals(graphemeCount("🇯🇵"), 1);
  assertEquals(graphemeCount("が"), 1);
  assertEquals(graphemeCount("が"), 1); // か＋濁点（結合文字）
  assertEquals(graphemeCount("あいう"), 3);
});

Deno.test("ニックネーム：2〜12文字（境界）", () => {
  assertEquals(validateNickname("あ").ok, false);
  assertEquals(validateNickname("あい").ok, true);
  assertEquals(validateNickname("あ".repeat(12)).ok, true);
  assertEquals(validateNickname("あ".repeat(13)).ok, false);
});

Deno.test("ニックネーム：絵文字は1文字として数える（12個までOK、家族の絵文字も1文字）", () => {
  assertEquals(validateNickname(FAMILY).ok, false); // 1文字
  assertEquals(validateNickname(FAMILY + FAMILY).ok, true); // 2文字
  assertEquals(validateNickname(FAMILY.repeat(12)).ok, true);
  assertEquals(validateNickname(FAMILY.repeat(13)).ok, false);
});

Deno.test("ニックネーム：全角・半角の違いで文字数が変わらない（NFKC後に数える）", () => {
  assertEquals(validateNickname("ＡＢＣＤＥＦＧＨＩＪＫＬ").ok, true); // 全角12文字
  assertEquals(validateNickname("ＡＢＣＤＥＦＧＨＩＪＫＬＭ").ok, false); // 全角13文字
});

Deno.test("ニックネーム：前後の空白は無視し、保存値は空白を除いたもの", () => {
  const v = validateNickname("  はなこ  ");
  assertEquals(v, { ok: true, value: "はなこ" });
});

Deno.test("ニックネーム：空・型違い・改行・制御文字は不可", () => {
  for (const input of ["", "   ", 123, null, undefined, "は\nなこ", "は\u0000なこ"]) {
    assertEquals(validateNickname(input).ok, false, String(input));
  }
});

Deno.test("自己紹介：100文字まで。空は null", () => {
  assertEquals(validateBio("あ".repeat(100)).ok, true);
  assertEquals(validateBio("あ".repeat(101)).ok, false);
  assertEquals(validateBio(FAMILY.repeat(100)).ok, true); // 絵文字100個＝100文字
  assertEquals(validateBio(""), { ok: true, value: null });
  assertEquals(validateBio(undefined), { ok: true, value: null });
  assertEquals(validateBio(5).ok, false);
});

Deno.test("年齢帯・アイコン・規約版の形式", () => {
  for (const band of ["age_0_1", "age_2_3", "age_4_6", "elementary", "junior_high_plus"]) {
    assertEquals(validateChildAgeRange(band), { ok: true, value: band }, band);
  }
  assertEquals(validateChildAgeRange(""), { ok: true, value: null });
  assertEquals(validateChildAgeRange(null), { ok: true, value: null });
  for (const bad of ["0〜1歳", "乳児", "age_7_9", " age_0_1", "AGE_0_1", 3]) {
    assertEquals(validateChildAgeRange(bad).ok, false, String(bad));
  }
  assertEquals(validateIconKey("sun"), { ok: true, value: "sun" });
  assertEquals(validateIconKey("../etc/passwd").ok, false);
  assertEquals(validateIconKey("Bear").ok, false);
  assertEquals(validateTermsVersion("2026-10"), { ok: true, value: "2026-10" });
  assertEquals(validateTermsVersion("").ok, false);
  assertEquals(validateTermsVersion(undefined).ok, false);
});
