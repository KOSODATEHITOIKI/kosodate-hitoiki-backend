/**
 * アップロード画像から、位置情報（GPS）などのメタデータを取り除く。
 *
 * 公開バケットへ保存した画像は、誰でもダウンロードして撮影場所などを読み取れる。そこで保存する前に、
 * 画像の構造を読み、**描画に必要な部分だけを残して**、それ以外（EXIF・XMP・コメント・ICC・サムネイル・
 * 画像の終端より後ろに付け足されたデータ）をすべて捨てる。許可リスト方式なので、未知の部分は残らない。
 * 画像そのものの再エンコードはしない（画質を落とさず、デコーダーの脆弱性にも触れない）。
 *
 * 読めない・壊れた画像は null を返す（保存しない）。
 *
 * JPEGの向き（EXIFのOrientation）だけは、位置情報を持たない最小のEXIFとして残す。
 * 捨てると、縦向きで撮った写真が横向きに表示されるため。
 */

const be16 = (b: Uint8Array, o: number) => (b[o] << 8) | b[o + 1];
const be32 = (b: Uint8Array, o: number) =>
  ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0;
const le32 = (b: Uint8Array, o: number) =>
  (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;

function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

const ascii = (b: Uint8Array, o: number, n: number) => String.fromCharCode(...b.subarray(o, o + n));

// --- JPEG ---

/** EXIF（APP1）からOrientation（1〜8）だけを読む。読めなければ 1。 */
function readExifOrientation(seg: Uint8Array): number {
  // seg: "Exif\0\0" + TIFFヘッダー
  if (seg.length < 14 || ascii(seg, 0, 4) !== "Exif" || seg[4] !== 0 || seg[5] !== 0) return 1;
  const t = 6;
  const little = seg[t] === 0x49 && seg[t + 1] === 0x49;
  const big = seg[t] === 0x4d && seg[t + 1] === 0x4d;
  if (!little && !big) return 1;
  const r16 = (o: number) => little ? seg[o] | (seg[o + 1] << 8) : (seg[o] << 8) | seg[o + 1];
  const r32 = (o: number) =>
    little
      ? (seg[o] | (seg[o + 1] << 8) | (seg[o + 2] << 16) | (seg[o + 3] << 24)) >>> 0
      : ((seg[o] << 24) | (seg[o + 1] << 16) | (seg[o + 2] << 8) | seg[o + 3]) >>> 0;
  if (r16(t + 2) !== 0x002a) return 1;
  const ifd = t + r32(t + 4);
  if (ifd + 2 > seg.length) return 1;
  const count = r16(ifd);
  for (let i = 0; i < count && i < 64; i++) {
    const e = ifd + 2 + i * 12;
    if (e + 12 > seg.length) return 1;
    if (r16(e) === 0x0112 && r16(e + 2) === 3) {
      const v = r16(e + 8);
      return v >= 1 && v <= 8 ? v : 1;
    }
  }
  return 1;
}

/** 向きだけを持つ最小のEXIF（APP1）。GPSなどのタグは持たない。 */
function orientationOnlyExif(orientation: number): Uint8Array {
  return Uint8Array.from([
    0xff,
    0xe1,
    0x00,
    0x22, // APP1、長さ34（長さ自身の2バイトを含む）
    0x45,
    0x78,
    0x69,
    0x66,
    0x00,
    0x00, // "Exif\0\0"
    0x4d,
    0x4d,
    0x00,
    0x2a,
    0x00,
    0x00,
    0x00,
    0x08, // ビッグエンディアンのTIFFヘッダー、IFD0は8バイト目
    0x00,
    0x01, // エントリ1つ
    0x01,
    0x12,
    0x00,
    0x03,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    orientation,
    0x00,
    0x00, // Orientation
    0x00,
    0x00,
    0x00,
    0x00, // 次のIFDなし
  ]);
}

export function stripJpeg(bytes: Uint8Array): Uint8Array | null {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  const kept: Uint8Array[] = [Uint8Array.of(0xff, 0xd8)];
  let orientation = 1;
  let pos = 2;
  let sawScan = false;

  while (pos < bytes.length) {
    if (bytes[pos] !== 0xff) return null;
    while (bytes[pos] === 0xff && pos + 1 < bytes.length) pos++; // 詰め物の0xFFを読み飛ばす
    const marker = bytes[pos++];
    if (marker === 0xd9) { // EOI：ここで終わり。後ろに付いたデータは捨てる
      if (!sawScan) return null;
      kept.push(Uint8Array.of(0xff, 0xd9));
      break;
    }
    if (marker === 0x00 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) continue;
    if (pos + 2 > bytes.length) return null;
    const len = be16(bytes, pos);
    if (len < 2 || pos + len > bytes.length) return null;
    const segment = bytes.subarray(pos + 2, pos + len);
    const whole = bytes.subarray(pos - 2, pos + len);

    if (marker === 0xe1) {
      const o = readExifOrientation(segment);
      if (o > orientation) orientation = o;
    }
    // 残すのは描画に必要なものだけ。APP0〜APP13・APP15（E0〜ED・EF）とコメント（FE）は捨てる。
    // APP14（EE、Adobe：色の変換）は描画に必要なので残す。
    const droppable = (marker >= 0xe0 && marker <= 0xef && marker !== 0xee) || marker === 0xfe;
    if (!droppable) kept.push(whole);
    pos += len;

    if (marker === 0xda) { // SOS：画像データ。次のマーカーまで（RSTと0xFF00は画像データの一部）
      sawScan = true;
      const start = pos;
      while (pos < bytes.length) {
        if (bytes[pos] === 0xff) {
          const next = bytes[pos + 1];
          if (next === undefined) return null;
          if (next === 0x00 || (next >= 0xd0 && next <= 0xd7) || next === 0xff) {
            pos += next === 0xff ? 1 : 2;
            continue;
          }
          break;
        }
        pos++;
      }
      kept.push(bytes.subarray(start, pos));
    }
  }
  if (!sawScan || kept[kept.length - 1].length !== 2 || kept[kept.length - 1][1] !== 0xd9) {
    return null;
  }
  if (orientation !== 1) kept.splice(1, 0, orientationOnlyExif(orientation));
  return concat(kept);
}

// --- PNG ---

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
/** 描画に必要なチャンクだけ。tEXt・zTXt・iTXt・eXIf・tIME・iCCP などは捨てる。 */
const PNG_KEEP = new Set([
  "IHDR",
  "PLTE",
  "tRNS",
  "IDAT",
  "IEND",
  "acTL",
  "fcTL",
  "fdAT",
  "gAMA",
  "cHRM",
  "sRGB",
  "sBIT",
  "bKGD",
]);

export function stripPng(bytes: Uint8Array): Uint8Array | null {
  if (bytes.length < 8 + 12 || !PNG_SIGNATURE.every((v, i) => bytes[i] === v)) return null;
  const kept: Uint8Array[] = [bytes.subarray(0, 8)];
  let pos = 8;
  let first = true;
  let sawData = false;
  while (pos + 12 <= bytes.length) {
    const len = be32(bytes, pos);
    const type = ascii(bytes, pos + 4, 4);
    const end = pos + 12 + len;
    if (end > bytes.length) return null;
    if (first && type !== "IHDR") return null;
    first = false;
    if (PNG_KEEP.has(type)) kept.push(bytes.subarray(pos, end));
    if (type === "IDAT") sawData = true;
    pos = end;
    if (type === "IEND") return sawData ? concat(kept) : null; // 後ろに付いたデータは捨てる
  }
  return null;
}

// --- WebP ---

/** 描画に必要なチャンクだけ。EXIF・XMP・ICCP などは捨てる。 */
const WEBP_KEEP = new Set(["VP8 ", "VP8L", "VP8X", "ALPH", "ANIM", "ANMF"]);

export function stripWebp(bytes: Uint8Array): Uint8Array | null {
  if (
    bytes.length < 20 || ascii(bytes, 0, 4) !== "RIFF" || ascii(bytes, 8, 4) !== "WEBP"
  ) return null;
  const declaredEnd = 8 + le32(bytes, 4);
  if (declaredEnd > bytes.length || declaredEnd < 12) return null;
  const chunks: Uint8Array[] = [];
  let pos = 12;
  let sawImage = false;
  while (pos + 8 <= declaredEnd) {
    const type = ascii(bytes, pos, 4);
    const size = le32(bytes, pos + 4);
    const padded = size + (size & 1);
    if (pos + 8 + padded > declaredEnd) return null;
    if (WEBP_KEEP.has(type)) {
      const chunk = bytes.slice(pos, pos + 8 + padded);
      if (type === "VP8X") {
        if (size < 10) return null;
        chunk[8] &= ~(0x20 | 0x08 | 0x04); // ICC・EXIF・XMPのフラグを下ろす
      }
      if (type === "VP8 " || type === "VP8L" || type === "ANMF") sawImage = true;
      chunks.push(chunk);
    }
    pos += 8 + padded;
  }
  if (!sawImage) return null;
  const body = concat(chunks);
  const header = new Uint8Array(12);
  header.set([0x52, 0x49, 0x46, 0x46], 0);
  new DataView(header.buffer).setUint32(4, 4 + body.length, true);
  header.set([0x57, 0x45, 0x42, 0x50], 8);
  return concat([header, body]);
}

/** 形式に応じてメタデータを取り除く。読めない・壊れた画像は null。 */
export function stripImageMetadata(bytes: Uint8Array, mimeType: string): Uint8Array | null {
  switch (mimeType) {
    case "image/jpeg":
      return stripJpeg(bytes);
    case "image/png":
      return stripPng(bytes);
    case "image/webp":
      return stripWebp(bytes);
    default:
      return null;
  }
}
