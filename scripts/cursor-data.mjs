/**
 * Turns a PNG cursor into the base64 RGBA blob the input relay embeds.
 *
 * The relay draws the pointer client-side with an EditableImage, which needs raw
 * pixels rather than a file. Roblox has no PNG decoder reachable from a
 * LocalScript and uploading the image as an asset would put a manual step
 * between cloning this repo and having a working cursor, so the pixels ship as
 * text inside the plugin.
 *
 * Usage: node scripts/cursor-data.mjs pointer.png 48
 */
import { readFileSync, writeFileSync } from "node:fs";
import { inflateSync } from "node:zlib";

/** Minimal PNG reader: enough for one small, non-interlaced cursor. */
function decodePng(file) {
  if (file.readUInt32BE(0) !== 0x8950_4e47) throw new Error("not a PNG");

  let width = 0;
  let height = 0;
  let depth = 0;
  let colour = 0;
  const idat = [];
  let palette = null;
  let alpha = null;

  let at = 8;
  while (at < file.length) {
    const length = file.readUInt32BE(at);
    const kind = file.toString("ascii", at + 4, at + 8);
    const body = file.subarray(at + 8, at + 8 + length);
    if (kind === "IHDR") {
      width = body.readUInt32BE(0);
      height = body.readUInt32BE(4);
      depth = body[8];
      colour = body[9];
      if (body[12] !== 0) throw new Error("interlaced PNGs are not supported");
    } else if (kind === "PLTE") palette = Buffer.from(body);
    else if (kind === "tRNS") alpha = Buffer.from(body);
    else if (kind === "IDAT") idat.push(Buffer.from(body));
    else if (kind === "IEND") break;
    at += 12 + length;
  }
  if (depth !== 8) throw new Error(`bit depth ${depth} is not supported`);

  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[colour];
  if (!channels) throw new Error(`colour type ${colour} is not supported`);

  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const out = Buffer.alloc(width * height * 4);
  const line = Buffer.alloc(stride);
  const prev = Buffer.alloc(stride);

  for (let row = 0; row < height; row += 1) {
    const filter = raw[row * (stride + 1)];
    raw.copy(line, 0, row * (stride + 1) + 1, row * (stride + 1) + 1 + stride);

    // The five PNG filters, each predicting a byte from its neighbours.
    for (let i = 0; i < stride; i += 1) {
      const a = i >= channels ? line[i - channels] : 0;
      const b = prev[i];
      const c = i >= channels ? prev[i - channels] : 0;
      let value = line[i];
      if (filter === 1) value += a;
      else if (filter === 2) value += b;
      else if (filter === 3) value += (a + b) >> 1;
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a);
        const pb = Math.abs(p - b);
        const pc = Math.abs(p - c);
        value += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      line[i] = value & 0xff;
    }

    for (let x = 0; x < width; x += 1) {
      const at4 = (row * width + x) * 4;
      const src = x * channels;
      if (colour === 6) {
        out[at4] = line[src];
        out[at4 + 1] = line[src + 1];
        out[at4 + 2] = line[src + 2];
        out[at4 + 3] = line[src + 3];
      } else if (colour === 2) {
        out[at4] = line[src];
        out[at4 + 1] = line[src + 1];
        out[at4 + 2] = line[src + 2];
        out[at4 + 3] = 255;
      } else if (colour === 0) {
        out[at4] = out[at4 + 1] = out[at4 + 2] = line[src];
        out[at4 + 3] = 255;
      } else if (colour === 4) {
        out[at4] = out[at4 + 1] = out[at4 + 2] = line[src];
        out[at4 + 3] = line[src + 1];
      } else if (colour === 3 && palette) {
        const index = line[src];
        out[at4] = palette[index * 3];
        out[at4 + 1] = palette[index * 3 + 1];
        out[at4 + 2] = palette[index * 3 + 2];
        out[at4 + 3] = alpha && index < alpha.length ? alpha[index] : 255;
      }
    }
    line.copy(prev);
  }

  return { width, height, rgba: out };
}

/** Box-filtered resize, so the downscaled cursor keeps a clean edge. */
function resize(src, sw, sh, size) {
  const out = Buffer.alloc(size * size * 4);
  const scaleX = sw / size;
  const scaleY = sh / size;
  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      const x0 = Math.floor(x * scaleX);
      const x1 = Math.max(x0 + 1, Math.floor((x + 1) * scaleX));
      const y0 = Math.floor(y * scaleY);
      const y1 = Math.max(y0 + 1, Math.floor((y + 1) * scaleY));
      let r = 0;
      let g = 0;
      let b = 0;
      let a = 0;
      let n = 0;
      for (let sy = y0; sy < Math.min(y1, sh); sy += 1) {
        for (let sx = x0; sx < Math.min(x1, sw); sx += 1) {
          const at = (sy * sw + sx) * 4;
          // Premultiplied, so transparent pixels do not drag colour into the edge.
          const alpha = src[at + 3] / 255;
          r += src[at] * alpha;
          g += src[at + 1] * alpha;
          b += src[at + 2] * alpha;
          a += src[at + 3];
          n += 1;
        }
      }
      const at = (y * size + x) * 4;
      const meanAlpha = a / n / 255;
      out[at] = meanAlpha > 0 ? Math.round(r / n / meanAlpha) : 0;
      out[at + 1] = meanAlpha > 0 ? Math.round(g / n / meanAlpha) : 0;
      out[at + 2] = meanAlpha > 0 ? Math.round(b / n / meanAlpha) : 0;
      out[at + 3] = Math.round(a / n);
    }
  }
  return out;
}

const [, , source, sizeArg, target] = process.argv;
const size = Number(sizeArg ?? 48);
const image = decodePng(readFileSync(source));
const scaled = resize(image.rgba, image.width, image.height, size);
writeFileSync(target, `${scaled.toString("base64")}\n`);
