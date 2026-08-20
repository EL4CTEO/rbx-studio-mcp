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
