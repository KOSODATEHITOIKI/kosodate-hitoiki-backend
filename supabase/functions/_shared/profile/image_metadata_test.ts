import { assert, assertEquals } from "@std/assert";
import { stripImageMetadata, stripJpeg, stripPng, stripWebp } from "./image_metadata.ts";

const enc = (s: string) => new TextEncoder().encode(s);
const cat = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
};
const contains = (hay: Uint8Array, needle: string) =>
  new TextDecoder("latin1").decode(hay).includes(needle);
const seg = (marker: number, payload: Uint8Array) =>
  cat(Uint8Array.of(0xff, marker, (payload.length + 2) >> 8, (payload.length + 2) & 0xff), payload);

// --- JPEG ---

/** GPSの文字列を含むEXIF（APP1）。Orientation=6（右に90度）つき。 */
function exifWithGps(orientation: number): Uint8Array {
  const header = Uint8Array.from([
    0x45,
    0x78,
    0x69,
    0x66,
    0x00,
    0x00, // Exif\0\0
    0x49,
    0x49,
    0x2a,
    0x00,
    0x08,
    0x00,
    0x00,
    0x00, // リトルエンディアン、IFD0は8
    0x02,
    0x00, // エントリ2つ
    0x12,
    0x01,
    0x03,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    orientation,
    0x00,
    0x00,
    0x00, // Orientation
    0x25,
    0x88,
    0x04,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x1a,
    0x00,
    0x00,
    0x00, // GPS IFDへのポインタ
    0x00,
    0x00,
    0x00,
    0x00,
  ]);
  return seg(0xe1, cat(header, enc("GPSLatitude=35.6586N GPSLongitude=139.7454E")));
}

function makeJpeg(opts: { orientation?: number; trailing?: string } = {}): Uint8Array {
  return cat(
    Uint8Array.of(0xff, 0xd8),
    seg(0xe0, enc("JFIF\0\x01\x01\0\0\x01\0\x01\0\0SECRET-THUMBNAIL")), // APP0
    exifWithGps(opts.orientation ?? 1),
    seg(0xe1, enc("http://ns.adobe.com/xap/1.0/\0<x:xmpmeta>SECRET-XMP</x:xmpmeta>")), // XMP
    seg(0xed, enc("Photoshop 3.0\0SECRET-IPTC")), // APP13
    seg(0xfe, enc("SECRET-COMMENT")), // COM
    seg(0xdb, new Uint8Array(65).fill(1)), // DQT
    seg(0xc0, Uint8Array.of(8, 0, 8, 0, 8, 1, 1, 0x11, 0)), // SOF0
    seg(0xc4, new Uint8Array(17).fill(2)), // DHT
    seg(0xda, Uint8Array.of(1, 1, 0, 0, 0x3f, 0)), // SOS
    Uint8Array.of(0x12, 0x34, 0xff, 0x00, 0x56, 0xff, 0xd0, 0x78), // 画像データ（0xFF00と RST0 を含む）
    Uint8Array.of(0xff, 0xd9),
    enc(opts.trailing ?? ""),
  );
}

Deno.test("JPEG：GPS・XMP・コメント・サムネイル・IPTCを取り除き、描画に必要な部分は残す", () => {
  const out = stripJpeg(makeJpeg({ trailing: "TRAILING-SECRET" }))!;
  assert(out);
  for (const s of ["GPS", "Latitude", "SECRET", "Exif", "xmpmeta", "JFIF", "TRAILING"]) {
    assert(!contains(out, s), `${s} が残っている`);
  }
  assertEquals([out[0], out[1]], [0xff, 0xd8]);
  assertEquals([out[out.length - 2], out[out.length - 1]], [0xff, 0xd9]);
  // 描画に必要な DQT・SOF0・DHT・SOS と画像データは残る
  assert(contains(out, "\xff\xdb") && contains(out, "\xff\xc0") && contains(out, "\xff\xc4"));
  assert(contains(out, "\xff\xda"));
  assert(contains(out, "\x12\x34\xff\x00\x56\xff\xd0\x78"), "画像データが壊れた");
});

Deno.test("JPEG：向き（Orientation）だけを、位置情報のない最小のEXIFとして残す", () => {
  const out = stripJpeg(makeJpeg({ orientation: 6 }))!;
  assert(!contains(out, "GPS"));
  // SOIの直後に、向きだけのEXIF（APP1）が入る
  assertEquals([out[2], out[3]], [0xff, 0xe1]);
  assert(contains(out, "Exif"));
  const exifStart = 2 + 4;
  // Orientation タグ（0x0112）の値が6
  const text = Array.from(out.subarray(exifStart, exifStart + 36));
  assertEquals(text.slice(6 + 8 + 2 + 8, 6 + 8 + 2 + 8 + 2), [0x00, 0x06]);
  // 向きが1（回転なし）のときは、EXIFも残さない
  assert(!contains(stripJpeg(makeJpeg({ orientation: 1 }))!, "Exif"));
});

Deno.test("JPEG：二度かけても同じ結果（冪等）。壊れた画像・画像データのないものは拒否する", () => {
  const once = stripJpeg(makeJpeg({ orientation: 3 }))!;
  assertEquals(stripJpeg(once), once);
  assertEquals(stripJpeg(Uint8Array.of(0xff, 0xd8, 0xff)), null);
  assertEquals(stripJpeg(enc("not a jpeg at all")), null);
  assertEquals(stripJpeg(makeJpeg().subarray(0, 40)), null); // 途中で切れている
  assertEquals(stripJpeg(cat(Uint8Array.of(0xff, 0xd8), Uint8Array.of(0xff, 0xd9))), null); // 画像データなし
});

// --- PNG ---

const png = {
  chunk: (type: string, data: Uint8Array) =>
    cat(
      Uint8Array.of(0, 0, 0, 0).map((_, i) => (data.length >> (24 - 8 * i)) & 0xff),
      enc(type),
      data,
      Uint8Array.of(0, 0, 0, 0), // CRC（検査しない）
    ),
};

function makePng(trailing = ""): Uint8Array {
  return cat(
    Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a),
    png.chunk("IHDR", new Uint8Array(13)),
    png.chunk("eXIf", enc("GPSLatitude=35.6586N SECRET")),
    png.chunk("tEXt", enc("Comment\0SECRET-TEXT")),
    png.chunk("iTXt", enc("XML:com.adobe.xmp\0SECRET-XMP")),
    png.chunk("tIME", new Uint8Array(7)),
    png.chunk("iCCP", enc("profile\0\0SECRET-ICC")),
    png.chunk("gAMA", new Uint8Array(4)),
    png.chunk("IDAT", enc("PIXELDATA")),
    png.chunk("IEND", new Uint8Array(0)),
    enc(trailing),
  );
}

Deno.test("PNG：eXIf・テキスト・XMP・時刻・ICCを取り除き、描画に必要なチャンクは残す", () => {
  const out = stripPng(makePng("TRAILING-SECRET"))!;
  assert(out);
  for (const s of ["GPS", "SECRET", "eXIf", "tEXt", "iTXt", "tIME", "iCCP", "TRAILING"]) {
    assert(!contains(out, s), `${s} が残っている`);
  }
  for (const s of ["IHDR", "gAMA", "IDAT", "PIXELDATA", "IEND"]) {
    assert(contains(out, s), `${s} が消えた`);
  }
  assertEquals(stripPng(out), out);
});

Deno.test("PNG：壊れた画像・IHDRで始まらない・画像データがない・IENDがないものは拒否する", () => {
  assertEquals(stripPng(enc("not a png")), null);
  assertEquals(stripPng(makePng().subarray(0, 50)), null);
  const sig = Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a);
  assertEquals(
    stripPng(cat(sig, png.chunk("IDAT", enc("x")), png.chunk("IEND", new Uint8Array(0)))),
    null,
  );
  assertEquals(
    stripPng(cat(sig, png.chunk("IHDR", new Uint8Array(13)), png.chunk("IEND", new Uint8Array(0)))),
    null,
  );
});

// --- WebP ---

function webpChunk(type: string, data: Uint8Array): Uint8Array {
  const header = new Uint8Array(8);
  header.set(enc(type), 0);
  new DataView(header.buffer).setUint32(4, data.length, true);
  return cat(header, data, data.length & 1 ? Uint8Array.of(0) : new Uint8Array(0));
}

function makeWebp(): Uint8Array {
  const flags = new Uint8Array(10);
  flags[0] = 0x20 | 0x08 | 0x04 | 0x10; // ICC・EXIF・XMP・アルファ
  const body = cat(
    webpChunk("VP8X", flags),
    webpChunk("ICCP", enc("SECRET-ICC")),
    webpChunk("VP8L", enc("PIXELS")),
    webpChunk("EXIF", enc("GPSLatitude=35.6586N SECRET-EXIF")),
    webpChunk("XMP ", enc("SECRET-XMP-ODD")),
  );
  const header = new Uint8Array(12);
  header.set(enc("RIFF"), 0);
  new DataView(header.buffer).setUint32(4, 4 + body.length, true);
  header.set(enc("WEBP"), 8);
  return cat(header, body);
}

Deno.test("WebP：EXIF・XMP・ICCを取り除き、フラグも下ろし、サイズを直す", () => {
  const out = stripWebp(makeWebp())!;
  assert(out);
  for (const s of ["GPS", "SECRET", "EXIF", "XMP ", "ICCP"]) {
    assert(!contains(out, s), `${s} が残っている`);
  }
  assert(contains(out, "VP8L") && contains(out, "PIXELS"));
  // VP8Xのフラグ：ICC(0x20)・EXIF(0x08)・XMP(0x04)は下りて、アルファ(0x10)は残る
  assertEquals(out[20], 0x10);
  // RIFFのサイズが実際の長さと一致する
  assertEquals(new DataView(out.buffer, out.byteOffset).getUint32(4, true), out.length - 8);
  assertEquals(stripWebp(out), out);
});

Deno.test("WebP：壊れた画像・画像データのないものは拒否する", () => {
  assertEquals(stripWebp(enc("RIFFxxxxWEBP")), null);
  assertEquals(stripWebp(makeWebp().subarray(0, 30)), null);
  const onlyMeta = cat(
    enc("RIFF"),
    Uint8Array.of(0, 0, 0, 0),
    enc("WEBP"),
    webpChunk("EXIF", enc("x")),
  );
  new DataView(onlyMeta.buffer).setUint32(4, onlyMeta.length - 8, true);
  assertEquals(stripWebp(onlyMeta), null);
});

Deno.test("形式の振り分け：未知の形式は拒否する", () => {
  assert(stripImageMetadata(makeJpeg(), "image/jpeg"));
  assert(stripImageMetadata(makePng(), "image/png"));
  assert(stripImageMetadata(makeWebp(), "image/webp"));
  assertEquals(stripImageMetadata(makeJpeg(), "image/gif"), null);
});
