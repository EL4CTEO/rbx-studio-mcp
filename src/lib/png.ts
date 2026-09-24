import { deflateSync } from "node:zlib";

/**
 * Writes a PNG from raw RGB bytes.
 *
 * The plugin used to do this itself, and could only do it badly. Studio has no
 * deflate, so the Luau encoder emitted zlib *stored* blocks -- the format's
 * escape hatch for "compression not applied" -- which meant every screenshot
 * travelled and landed at full uncompressed size. For a screen of mostly flat
 * colour that is several times larger than it needs to be, and it is spent
 * twice: once over the bridge and again as base64 in the conversation.
 *
 * Node has real zlib. So the plugin now sends pixels and this writes the file,
 * which is the right division: the side with the compressor does the
 * compressing.
 */

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let index = 0; index < 256; index += 1) {
    let value = index;
    for (let bit = 0; bit < 8; bit += 1) {
      // 0xEDB88320: the reversed CRC-32 polynomial. Worth writing out, because
      // a single wrong digit here (0xED888320) still produces a table, still
      // produces a checksum, and still produces a PNG that every decoder
      // rejects — with nothing in the file to say which byte was wrong.
      value = value & 1 ? 0xedb8_8320 ^ (value >>> 1) : value >>> 1;
    }
    table[index] = value;
  }
  return table;
})();

function crc32(data: Buffer): number {
  let crc = -1;
  for (const byte of data) {
    crc = CRC_TABLE[(crc ^ byte) & 0xff]! ^ (crc >>> 8);
  }
  return (crc ^ -1) >>> 0;
}

/** One PNG chunk: length, type, payload, CRC over type+payload. */
function chunk(kind: string, payload: Buffer): Buffer {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(payload.length, 0);
  const body = Buffer.concat([Buffer.from(kind, "ascii"), payload]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([length, body, crc]);
}

const SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/**
 * Encodes `width` x `height` RGB triples as a PNG.
 *
 * Filter type 0 (None) on every scanline. The adaptive filters PNG allows would
 * compress better, but choosing between them well is its own problem, and
 * deflate over unfiltered rows already recovers almost all of what the old
 * stored-block encoder was throwing away.
 */
export function encodePng(rgb: Buffer, width: number, height: number): Buffer {
  const stride = width * 3;
  const expected = stride * height;
  if (rgb.length < expected) {
    throw new Error(
      `pixel data is ${rgb.length} bytes, short of the ${expected} needed for ${width}x${height}`,
    );
  }

  // One leading filter byte per row is what separates the raw pixels from a
  // PNG's idea of a scanline.
  const raw = Buffer.alloc((stride + 1) * height);
  for (let row = 0; row < height; row += 1) {
    raw[row * (stride + 1)] = 0;
    rgb.copy(raw, row * (stride + 1) + 1, row * stride, row * stride + stride);
  }

  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8; // bit depth
  header[9] = 2; // colour type 2: truecolour RGB
  header[10] = 0; // deflate
  header[11] = 0; // adaptive filtering
  header[12] = 0; // no interlace

  return Buffer.concat([
    SIGNATURE,
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

/**
 * For one axis: which source pixels each output pixel covers, and how much of
 * each. Flat typed arrays rather than nested lists -- this runs per pixel.
 */
function coverage(inSize: number, outSize: number): { first: Int32Array; count: Int32Array; weight: Float32Array; taps: number } {
  const span = inSize / outSize;
  const taps = Math.ceil(span) + 1;
  const first = new Int32Array(outSize);
  const count = new Int32Array(outSize);
  const weight = new Float32Array(outSize * taps);
  for (let out = 0; out < outSize; out += 1) {
    const from = out * span;
    const to = from + span;
    const low = Math.floor(from);
    const high = Math.min(inSize, Math.ceil(to));
    first[out] = low;
    count[out] = high - low;
    for (let source = low; source < high; source += 1) {
      weight[out * taps + source - low] = Math.max(0, Math.min(to, source + 1) - Math.max(from, source)) / span;
    }
  }
  return { first, count, weight, taps };
}

/**
 * Scales RGB pixels down to `outWidth` wide with a box filter.
 *
 * Each output pixel is the area-weighted average of every source pixel under
 * it. Bilinear sampling, which the engine uses, reads four pixels per output
 * pixel however large the reduction -- past 2x it skips the rest, so thin
 * lines and small GUI text break apart. Never scales up: that adds no detail.
 */
export function boxResample(
  rgb: Buffer,
  width: number,
  height: number,
  outWidth: number,
): { rgb: Buffer; width: number; height: number } {
  if (outWidth >= width) return { rgb, width, height };
  const outHeight = Math.max(1, Math.round((height * outWidth) / width));

  // Horizontal, then vertical: separable, so each pass is a short weighted sum.
  const across = coverage(width, outWidth);
  const wide = new Float32Array(outWidth * height * 3);
  for (let row = 0; row < height; row += 1) {
    const inRow = row * width * 3;
    const outRow = row * outWidth * 3;
    for (let out = 0; out < outWidth; out += 1) {
      let r = 0;
      let g = 0;
      let b = 0;
      let at = inRow + across.first[out]! * 3;
      const base = out * across.taps;
      for (let tap = 0, n = across.count[out]!; tap < n; tap += 1, at += 3) {
        const w = across.weight[base + tap]!;
        r += rgb[at]! * w;
        g += rgb[at + 1]! * w;
        b += rgb[at + 2]! * w;
      }
      const to = outRow + out * 3;
      wide[to] = r;
      wide[to + 1] = g;
      wide[to + 2] = b;
    }
  }

  const down = coverage(height, outHeight);
  const rowLength = outWidth * 3;
  const sums = new Float32Array(rowLength);
  const result = Buffer.alloc(rowLength * outHeight);
  for (let out = 0; out < outHeight; out += 1) {
    sums.fill(0);
    const base = out * down.taps;
    for (let tap = 0, n = down.count[out]!; tap < n; tap += 1) {
      const w = down.weight[base + tap]!;
      const inRow = (down.first[out]! + tap) * rowLength;
      for (let index = 0; index < rowLength; index += 1) sums[index] = sums[index]! + wide[inRow + index]! * w;
    }
    const outRow = out * rowLength;
    for (let index = 0; index < rowLength; index += 1) {
      result[outRow + index] = Math.min(255, Math.max(0, Math.round(sums[index]!)));
    }
  }
  return { rgb: result, width: outWidth, height: outHeight };
}

/**
 * Enlarges by a whole factor, each pixel becoming a k x k block.
 *
 * For small zoomed crops: an image a hundred pixels wide is a handful of
 * patches to a vision model, which then misreads what is in it. Nearest
 * neighbour adds no detail and invents none either -- the pixels are the
 * capture's, only bigger.
 */
export function upscaleNearest(
  rgb: Buffer,
  width: number,
  height: number,
  factor: number,
): { rgb: Buffer; width: number; height: number } {
  if (factor <= 1) return { rgb, width, height };
  const outWidth = width * factor;
  const out = Buffer.alloc(outWidth * height * factor * 3);
  for (let y = 0; y < height; y += 1) {
    const row = Buffer.alloc(outWidth * 3);
    for (let x = 0; x < width; x += 1) {
      const from = (y * width + x) * 3;
      for (let k = 0; k < factor; k += 1) rgb.copy(row, (x * factor + k) * 3, from, from + 3);
    }
    for (let k = 0; k < factor; k += 1) row.copy(out, (y * factor + k) * outWidth * 3);
  }
  return { rgb: out, width: outWidth, height: height * factor };
}
