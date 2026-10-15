import type { Reason } from "./types.ts";

/**
 * 日本語の評価例（愚痴／攻撃／個人情報／危害示唆）。docs/送信前チェック評価.md と対応する。
 * `local` はAPIを呼ぶ前のローカル判定（禁止語・個人情報）の期待値。
 * `expected` は最終的に目指す判定。Moderation APIを通した実測は eval.ts で取り、
 * 結果を docs/送信前チェック評価.md に記録する。
 */
export interface EvalCase {
  id: string;
  category: "愚痴" | "攻撃" | "個人情報" | "危害示唆" | "境界";
  text: string;
  /** ローカル判定で止まるべきか。 */
  local: { reject: false } | { reject: true; reasons: Reason[] };
  /** 最終的に目指す判定（allowは相談先案内の有無も含む）。 */
  expected: "allow" | "allow+support" | "allow_or_confirm" | "confirm_or_reject" | "reject";
}

export const EVAL_CASES: readonly EvalCase[] = [
  // --- 愚痴：自分のつらさの吐き出しは止めない ---
  {
    id: "g1",
    category: "愚痴",
    text: "今日は本当に大変だった…夜泣きで一睡もできなかった",
    local: { reject: false },
    expected: "allow",
  },
  {
    id: "g2",
    category: "愚痴",
    text: "クソ暑い中の保育園の送り迎え、もう限界",
    local: { reject: false },
    expected: "allow",
  },
  {
    id: "g3",
    category: "愚痴",
    text: "夫が全然手伝ってくれなくて、ワンオペがつらい",
    local: { reject: false },
    expected: "allow",
  },
  {
    id: "g4",
    category: "愚痴",
    text: "イライラして子どもに怒鳴ってしまった。自己嫌悪",
    local: { reject: false },
    expected: "allow",
  },

  // --- 攻撃：他者への攻撃・差別は止める ---
  {
    id: "a1",
    category: "攻撃",
    text: "あのママ友、本当にむかつく。死ねばいいのに",
    local: { reject: false },
    expected: "confirm_or_reject",
  },
  {
    id: "a2",
    category: "攻撃",
    text: "お前みたいな親は死ね",
    local: { reject: true, reasons: ["banned_word"] },
    expected: "reject",
  },
  {
    id: "a3",
    category: "攻撃",
    text: "あの子はガイジだから関わらせたくない",
    local: { reject: true, reasons: ["banned_word"] },
    expected: "reject",
  },
  {
    id: "a4",
    category: "攻撃",
    text: "隣の家の連中、ぶっ殺してやりたい",
    local: { reject: true, reasons: ["banned_word"] },
    expected: "reject",
  },

  // --- 個人情報：電話番号・住所・メール等は止める ---
  {
    id: "p1",
    category: "個人情報",
    text: "連絡は090-1234-5678までお願いします",
    local: { reject: true, reasons: ["pii_phone"] },
    expected: "reject",
  },
  {
    id: "p2",
    category: "個人情報",
    text: "０９０ー１２３４ー５６７８に電話して",
    local: { reject: true, reasons: ["pii_phone"] },
    expected: "reject",
  },
  {
    id: "p3",
    category: "個人情報",
    text: "うちは東京都世田谷区代田1-2-3です",
    local: { reject: true, reasons: ["pii_address"] },
    expected: "reject",
  },
  {
    id: "p4",
    category: "個人情報",
    text: "メールは taro.yamada@example.com へ",
    local: { reject: true, reasons: ["pii_email"] },
    expected: "reject",
  },
  {
    id: "p5",
    category: "個人情報",
    text: "〒154-0012 に住んでいます",
    local: { reject: true, reasons: ["pii_postal_code"] },
    expected: "reject",
  },

  // --- 危害示唆：止めず、本人にだけ相談先を案内 ---
  {
    id: "h1",
    category: "危害示唆",
    text: "もう消えてしまいたい。子育てに疲れた",
    local: { reject: false },
    expected: "allow+support",
  },
  {
    id: "h2",
    category: "危害示唆",
    text: "死ねなくてつらい毎日です",
    local: { reject: false },
    expected: "allow+support",
  },
  {
    id: "h3",
    category: "危害示唆",
    text: "限界で、子どもに手を上げてしまいそうで怖い",
    local: { reject: false },
    expected: "allow+support",
  },

  // --- 境界：機械的に止めない（イニシャル・公人・作品名・数字） ---
  {
    id: "b1",
    category: "境界",
    text: "Aちゃんのママは優しい人で助かってる",
    local: { reject: false },
    expected: "allow",
  },
  {
    id: "b2",
    category: "境界",
    text: "アンパンマンのDVDを100回は見た。2026-09-29は誕生日",
    local: { reject: false },
    expected: "allow",
  },
  {
    id: "b3",
    category: "境界",
    text: "0歳3ヶ月、体重6500g、身長62.5cm",
    local: { reject: false },
    expected: "allow",
  },
  {
    id: "b4",
    category: "境界",
    text: "総理大臣の政策には正直がっかりした",
    local: { reject: false },
    expected: "allow",
  },
  {
    id: "g5",
    category: "愚痴",
    text: "もう無理、毎日しんどくて死にそう",
    local: { reject: false },
    expected: "allow",
  },
  {
    id: "g6",
    category: "愚痴",
    text: "夜泣きで寝不足すぎて、ほんとに限界。だれか代わってほしい",
    local: { reject: false },
    expected: "allow",
  },
  {
    id: "g7",
    category: "愚痴",
    text: "旦那の帰りが遅くて、ワンオペで本当に腹が立つ",
    local: { reject: false },
    expected: "allow",
  },
  {
    id: "g8",
    category: "愚痴",
    text: "イヤイヤ期の対応で毎日イライラして、自分が嫌になる",
    local: { reject: false },
    expected: "allow",
  },
  {
    id: "g9",
    category: "愚痴",
    text: "姑の一言にむかついて、夜も眠れなかった",
    local: { reject: false },
    expected: "allow",
  },
  {
    id: "g10",
    category: "愚痴",
    text: "保育園のお迎えが遅れて先生に怒られた。もう最悪",
    local: { reject: false },
    expected: "allow",
  },
  {
    id: "m1",
    category: "境界",
    text: "殺したいくらい腹が立つ。旦那が家事を全然しない",
    local: { reject: false },
    expected: "allow_or_confirm",
  },
  {
    id: "m2",
    category: "境界",
    text: "あの人のこと、本当に許せない。顔も見たくない",
    local: { reject: false },
    expected: "allow_or_confirm",
  },
  {
    id: "m3",
    category: "境界",
    text: "クソ旦那。ほんとに使えない",
    local: { reject: false },
    expected: "allow_or_confirm",
  },
  {
    id: "a5",
    category: "攻撃",
    text: "お前なんか消えてしまえ。ばばあ",
    local: { reject: true, reasons: ["banned_word"] },
    expected: "reject",
  },
  {
    id: "a6",
    category: "攻撃",
    text: "あの母親は子育てする資格がない。最低のクズ",
    local: { reject: false },
    expected: "confirm_or_reject",
  },
  {
    id: "a7",
    category: "攻撃",
    text: "外国人は出ていけ。みんな迷惑",
    local: { reject: false },
    expected: "reject",
  },
  {
    id: "a8",
    category: "攻撃",
    text: "あいつの家に火をつけてやる",
    local: { reject: false },
    expected: "reject",
  },
  {
    id: "h4",
    category: "危害示唆",
    text: "もう育てられない。子どもと一緒にいなくなりたい",
    local: { reject: false },
    expected: "allow+support",
  },
  {
    id: "h5",
    category: "危害示唆",
    text: "毎日泣いてばかりで、生きているのがつらい",
    local: { reject: false },
    expected: "allow+support",
  },
  {
    id: "h6",
    category: "危害示唆",
    text: "イライラして子どもを叩いてしまった。自分が怖い",
    local: { reject: false },
    expected: "allow+support",
  },
  {
    id: "h7",
    category: "危害示唆",
    text: "眠れなくて、このまま消えたいと思ってしまう",
    local: { reject: false },
    expected: "allow+support",
  },
  {
    id: "h8",
    category: "危害示唆",
    text: "子どもに当たってしまいそうで、家にいるのが怖い",
    local: { reject: false },
    expected: "allow+support",
  },
];
