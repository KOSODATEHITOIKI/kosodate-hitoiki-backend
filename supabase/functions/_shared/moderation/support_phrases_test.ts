import { assertEquals } from "@std/assert";
import { containsBannedWord } from "./banned_words.ts";
import { EVAL_CASES } from "./eval_cases.ts";
import { normalizeForDetection } from "./normalize.ts";
import { needsSupportNotice } from "./support_phrases.ts";

const support = (t: string) => needsSupportNotice(normalizeForDetection(t));
const banned = (t: string) => containsBannedWord(normalizeForDetection(t));

Deno.test("相談先案内の表現：自分の消えたい気持ち・生きるつらさ", () => {
  for (
    const t of [
      "もう消えてしまいたい",
      "毎日死にたい気持ちになる",
      "子育てに疲れて、いなくなりたい",
      "生きているのがつらい",
      "生きていくのがしんどい",
      "眠れなくて、このまま消えたいと思ってしまう",
    ]
  ) assertEquals(support(t), true, t);
});

Deno.test("相談先案内の表現：子どもへの加害の不安・加害してしまったこと（APIが検知しない）", () => {
  for (
    const t of [
      "限界で、子どもに手を上げてしまいそうで怖い",
      "子どもに当たってしまいそうで、家にいるのが怖い",
      "イライラして子どもを叩いてしまった",
      "息子に手をあげてしまった。自分が怖い",
      "虐待してしまいそうで不安",
      "もう育てられない。子どもと一緒にいなくなりたい",
    ]
  ) assertEquals(support(t), true, t);
});

Deno.test("相談先案内の表現：日常の言い回しや、ほかの愚痴には反応しない", () => {
  for (
    const t of [
      "子どもが手を上げて横断歩道をわたった",
      "今日は本当に大変だった…夜泣きで一睡もできなかった",
      "夫が全然手伝ってくれなくて、ワンオペがつらい",
      "イライラして子どもに怒鳴ってしまった。自己嫌悪",
      "おやつが一瞬で消えた",
      "クソ暑い中の保育園の送迎、もう限界",
      "ドラムを叩く練習をしている",
      "私が怖い映画を見て眠れなかった",
      "旦那が全然手伝ってくれない。腹が立つ",
    ]
  ) assertEquals(support(t), false, t);
});

Deno.test("評価例の愚痴（g）・境界（b）には、表現リストで案内を出さない（g5「死にそう」の誇張はAPI側）", () => {
  for (const c of EVAL_CASES.filter((c) => /^(g\d+|b\d+)$/.test(c.id))) {
    assertEquals(support(c.text), false, `${c.id}: ${c.text}`);
  }
});

Deno.test("禁止語：他者への直接の死の願望を止める。自分への「消えてしまいたい」は止めない", () => {
  for (const t of ["お前なんか消えてしまえ", "いなくなれ", "くたばれ", "消えろ"]) {
    assertEquals(banned(t), true, t);
  }
  for (
    const t of [
      "もう消えてしまいたい",
      "いなくなりたい",
      "この世からいなくなりたいと思う日がある",
      "疲れて消えてなくなりたい",
    ]
  ) assertEquals(banned(t), false, t);
});
