/**
 * Draws the plugin icon: the panel's diamond on a navy tile, with a small
 * constellation joined to it.
 *
 * Both outputs come from this one description so they cannot drift apart:
 * the SVG for anywhere that takes vector, the PNG for the Roblox upload that
 * the toolbar button points at. The PNG is rasterised here with 4x4
 * supersampling -- every shape is a diamond, a line or a rounded square, so no
 * rasteriser library is needed.
 *
 * Usage: node scripts/icon.mjs assets/icon.svg assets/icon.png
 */
import { writeFileSync } from "node:fs";
import { crc32, deflateSync } from "node:zlib";

const SIZE = 512;
const C = SIZE / 2;

// Palette: Nebula, the default theme.
const TOP = [18, 59, 122];
const BOTTOM = [6, 23, 51];
const LINE = [120, 190, 255];
const CORE = [232, 241, 255];

// The constellation: three stars around the central diamond.
const STARS = [
  { x: 112, y: 132, r: 16 },
  { x: 404, y: 150, r: 12 },
  { x: 380, y: 398, r: 14 },
];
const OUTER = 138; // centre diamond half-diagonal
const STROKE = 22;
const INNER = 62;

function encodePng(rgba, width, height) {
  const chunk = (kind, payload) => {
    const out = Buffer.alloc(payload.length + 12);
    out.writeUInt32BE(payload.length, 0);
    out.write(kind, 4, "ascii");
    payload.copy(out, 8);
    out.writeUInt32BE(crc32(out.subarray(4, 8 + payload.length)), 8 + payload.length);
    return out;
  };
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0;
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6; // RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

function segmentDistance(px, py, ax, ay, bx, by) {
  const dx = bx - ax;
  const dy = by - ay;
  const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)));
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

function inRoundedSquare(x, y, inset, radius) {
  const lo = inset;
  const hi = SIZE - inset;
  if (x < lo || x > hi || y < lo || y > hi) return false;
  const cx = Math.min(Math.max(x, lo + radius), hi - radius);
  const cy = Math.min(Math.max(y, lo + radius), hi - radius);
  return Math.hypot(x - cx, y - cy) <= radius;
}

const mix = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);

// The colour (and alpha) at one sample point, painter's order.
function sample(x, y) {
  if (!inRoundedSquare(x, y, 8, 96)) return [0, 0, 0, 0];
  const t = (x + y) / (2 * SIZE);
  let color = mix(TOP, BOTTOM, t);
  const over = (rgb, a) => {
    color = mix(color, rgb, a);
  };

  // Constellation lines: each star to the nearest tip of the diamond.
  const tips = [
    [C, C - OUTER],
    [C + OUTER, C],
    [C, C + OUTER],
    [C - OUTER, C],
  ];
  for (const s of STARS) {
    let best = tips[0];
    for (const tip of tips) {
      if (Math.hypot(tip[0] - s.x, tip[1] - s.y) < Math.hypot(best[0] - s.x, best[1] - s.y)) best = tip;
    }
    if (segmentDistance(x, y, s.x, s.y, best[0], best[1]) <= 3) over(LINE, 0.55);
  }
  if (segmentDistance(x, y, STARS[0].x, STARS[0].y, STARS[1].x, STARS[1].y) <= 2.5) over(LINE, 0.3);

  // Soft glow behind the core.
  const glow = Math.exp(-((x - C) ** 2 + (y - C) ** 2) / (2 * 70 ** 2));
  over(LINE, glow * 0.35);

  // The diamond's outline.
  const d = Math.abs(x - C) + Math.abs(y - C);
  if (d <= OUTER && d >= OUTER - STROKE * Math.SQRT2) over(LINE, 1);
  // The bright core.
  if (d <= INNER) over(CORE, 1);
  // The stars.
  for (const s of STARS) {
    if (Math.abs(x - s.x) + Math.abs(y - s.y) <= s.r) over(CORE, 1);
  }
  return [...color, 255];
}

function renderPng(path) {
  const N = 4;
  const rgba = Buffer.alloc(SIZE * SIZE * 4);
  for (let py = 0; py < SIZE; py++) {
    for (let px = 0; px < SIZE; px++) {
      const sum = [0, 0, 0, 0];
      for (let sy = 0; sy < N; sy++) {
        for (let sx = 0; sx < N; sx++) {
          const [r, g, b, a] = sample(px + (sx + 0.5) / N, py + (sy + 0.5) / N);
          sum[0] += r * a;
          sum[1] += g * a;
          sum[2] += b * a;
          sum[3] += a;
        }
      }
      const o = (py * SIZE + px) * 4;
      const alpha = sum[3] / (N * N);
      rgba[o] = sum[3] ? Math.round(sum[0] / sum[3]) : 0;
      rgba[o + 1] = sum[3] ? Math.round(sum[1] / sum[3]) : 0;
      rgba[o + 2] = sum[3] ? Math.round(sum[2] / sum[3]) : 0;
      rgba[o + 3] = Math.round(alpha);
    }
  }
  writeFileSync(path, encodePng(rgba, SIZE, SIZE));
}

function renderSvg(path) {
  const hex = (rgb) => `#${rgb.map((v) => Math.round(v).toString(16).padStart(2, "0")).join("")}`;
  const diamond = (r) => `${C},${C - r} ${C + r},${C} ${C},${C + r} ${C - r},${C}`;
  const tips = [
    [C, C - OUTER],
    [C + OUTER, C],
    [C, C + OUTER],
    [C - OUTER, C],
  ];
  const lines = STARS.map((s) => {
    const best = tips.reduce((a, b) => (Math.hypot(b[0] - s.x, b[1] - s.y) < Math.hypot(a[0] - s.x, a[1] - s.y) ? b : a));
    return `<line x1="${s.x}" y1="${s.y}" x2="${best[0]}" y2="${best[1]}" stroke="${hex(LINE)}" stroke-opacity="0.55" stroke-width="6"/>`;
  });
  lines.push(
    `<line x1="${STARS[0].x}" y1="${STARS[0].y}" x2="${STARS[1].x}" y2="${STARS[1].y}" stroke="${hex(LINE)}" stroke-opacity="0.3" stroke-width="5"/>`,
  );
  const stars = STARS.map(
    (s) => `<polygon points="${s.x},${s.y - s.r} ${s.x + s.r},${s.y} ${s.x},${s.y + s.r} ${s.x - s.r},${s.y}" fill="${hex(CORE)}"/>`,
  );
  const outerMid = OUTER - (STROKE * Math.SQRT2) / 2;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${SIZE} ${SIZE}" width="${SIZE}" height="${SIZE}" role="img" aria-label="rbx-studio">
  <title>rbx-studio</title>
  <desc>The panel's diamond on a navy tile, joined to a small constellation.</desc>
  <defs>
    <linearGradient id="tile" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="${hex(TOP)}"/>
      <stop offset="1" stop-color="${hex(BOTTOM)}"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="${hex(LINE)}" stop-opacity="0.35"/>
      <stop offset="1" stop-color="${hex(LINE)}" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect x="8" y="8" width="${SIZE - 16}" height="${SIZE - 16}" rx="96" fill="url(#tile)"/>
  ${lines.join("\n  ")}
  <circle cx="${C}" cy="${C}" r="170" fill="url(#glow)"/>
  <polygon points="${diamond(outerMid)}" fill="none" stroke="${hex(LINE)}" stroke-width="${(STROKE * Math.SQRT2).toFixed(1)}" stroke-linejoin="miter"/>
  <polygon points="${diamond(INNER)}" fill="${hex(CORE)}"/>
  ${stars.join("\n  ")}
</svg>
`;
  writeFileSync(path, svg);
}

const [svgPath = "assets/icon.svg", pngPath = "assets/icon.png"] = process.argv.slice(2);
renderSvg(svgPath);
renderPng(pngPath);
console.log(`wrote ${svgPath} and ${pngPath}`);
