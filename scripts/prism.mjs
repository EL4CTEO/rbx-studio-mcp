/**
 * Draws the project mark: a triangular prism splitting white light.
 *
 * Both outputs come from this one file because they have to agree. The SVG is
 * for anywhere that takes vector; the PNG exists because GitHub, npm and most
 * other places reject SVG for an avatar, and hand-keeping two drawings in sync
 * is how they end up different.
 *
 * There is no rasteriser installed and the shapes do not need one: the body is
 * three flat polygons and the light is a set of bands with a Gaussian falloff
 * across their width. The PNG is written by the same encoder behind the
 * `screenshot` tool.
 *
 * Usage: node scripts/prism.mjs docs/prism.svg docs/prism.png
 */
import { writeFileSync } from "node:fs";
import { encodePng } from "../dist/lib/png.js";

const SIZE = 512;
const SS = 3; // subsamples per axis

// --- geometry --------------------------------------------------------------

const A = [238, 142]; // apex
const B = [146, 322]; // bottom left
const C = [330, 322]; // bottom right
const DEPTH = [40, -24]; // extrusion, up and to the right

const add = (p, q) => [p[0] + q[0], p[1] + q[1]];
const mix = (p, q, t) => [p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t];

const A2 = add(A, DEPTH);
const B2 = add(B, DEPTH);
const C2 = add(C, DEPTH);

const FRONT = [A, B, C];
const SIDE = [A, C, C2, A2]; // the only extruded face facing the viewer

// Where the beam enters the left face and leaves the right one. Both sit on an
// edge rather than near a corner, so the light visibly passes through the body.
const ENTRY = mix(A, B, 0.55);
const EXIT = mix(A, C, 0.62);
const SOURCE = [24, 196];

/**
 * The spectrum, ordered by how far each colour bends.
 *
 * Red deviates least and violet most, which is the whole reason a prism
 * separates them, so red leaves closest to the original path and violet swings
 * furthest toward the base. Reversing this is the usual tell that a prism
 * drawing was copied rather than understood.
 */
const SPECTRUM = [
  { angle: 6, color: [255, 64, 72] },
  { angle: 11, color: [255, 138, 48] },
  { angle: 16, color: [255, 214, 66] },
  { angle: 21, color: [88, 230, 122] },
  { angle: 26, color: [70, 210, 255] },
  { angle: 31, color: [96, 132, 255] },
  { angle: 36, color: [176, 106, 255] },
];

const FAN_LENGTH = 190;
const BG = [10, 14, 26];

const rad = (deg) => (deg * Math.PI) / 180;

/** A light band: origin, direction, and how wide it is at each end. */
function band(origin, angleDeg, length, w0, w1) {
  const t = rad(angleDeg);
  return {
    origin,
    dir: [Math.cos(t), Math.sin(t)],
    perp: [-Math.sin(t), Math.cos(t)],
    length,
    w0,
    w1,
  };
}

const FAN = SPECTRUM.map((s) => ({
  ...s,
  band: band(EXIT, s.angle, FAN_LENGTH, 3, 15),
}));

const INCOMING = (() => {
  const d = [ENTRY[0] - SOURCE[0], ENTRY[1] - SOURCE[1]];
  const len = Math.hypot(d[0], d[1]);
  return { band: band(SOURCE, (Math.atan2(d[1], d[0]) * 180) / Math.PI, len, 7, 4), color: [255, 255, 255] };
})();

const INTERNAL = (() => {
  const d = [EXIT[0] - ENTRY[0], EXIT[1] - ENTRY[1]];
  const len = Math.hypot(d[0], d[1]);
  return { band: band(ENTRY, (Math.atan2(d[1], d[0]) * 180) / Math.PI, len, 4, 6), color: [220, 235, 255] };
})();

/** Corners of a band, for the SVG. */
function bandPoints(b) {
  const s = b.origin;
  const e = [s[0] + b.dir[0] * b.length, s[1] + b.dir[1] * b.length];
  const off = (p, w, sign) => [p[0] + b.perp[0] * w * sign, p[1] + b.perp[1] * w * sign];
  return [off(s, b.w0, -1), off(e, b.w1, -1), off(e, b.w1, 1), off(s, b.w0, 1)];
}

// --- SVG -------------------------------------------------------------------

const n = (v) => Math.round(v * 10) / 10;
const poly = (pts) => pts.map((p) => `${n(p[0])},${n(p[1])}`).join(" ");
const rgb = (c) => `rgb(${c[0]},${c[1]},${c[2]})`;

function svg() {
  const beams = [];
  for (const [i, f] of FAN.entries()) {
    const pts = bandPoints(f.band);
    beams.push(
      `<linearGradient id="g${i}" gradientUnits="userSpaceOnUse" ` +
        `x1="${n(EXIT[0])}" y1="${n(EXIT[1])}" ` +
        `x2="${n(pts[1][0])}" y2="${n(pts[1][1])}">` +
        `<stop offset="0" stop-color="${rgb(f.color)}" stop-opacity="0.95"/>` +
        `<stop offset="0.55" stop-color="${rgb(f.color)}" stop-opacity="0.5"/>` +
        `<stop offset="1" stop-color="${rgb(f.color)}" stop-opacity="0"/>` +
        `</linearGradient>`,
    );
  }

  const fan = FAN.map((f, i) => `<polygon points="${poly(bandPoints(f.band))}" fill="url(#g${i})"/>`).join("\n      ");

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${SIZE} ${SIZE}" width="${SIZE}" height="${SIZE}" role="img" aria-label="A prism splitting a beam of white light into a spectrum">
  <title>rbx-studio-mcp</title>
  <defs>
    ${beams.join("\n    ")}
    <linearGradient id="face" gradientUnits="userSpaceOnUse" x1="${n(A[0])}" y1="${n(A[1])}" x2="${n(C[0])}" y2="${n(C[1])}">
      <stop offset="0" stop-color="#AFC0E8" stop-opacity="0.30"/>
      <stop offset="1" stop-color="#5C6E9E" stop-opacity="0.16"/>
    </linearGradient>
    <linearGradient id="side" gradientUnits="userSpaceOnUse" x1="${n(A[0])}" y1="${n(A[1])}" x2="${n(C2[0])}" y2="${n(C2[1])}">
      <stop offset="0" stop-color="#8FA2D0" stop-opacity="0.26"/>
      <stop offset="1" stop-color="#39456A" stop-opacity="0.34"/>
    </linearGradient>
    <radialGradient id="flare">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.85"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <filter id="soft" x="-40%" y="-40%" width="180%" height="180%">
      <feGaussianBlur stdDeviation="5"/>
    </filter>
  </defs>

  <rect width="${SIZE}" height="${SIZE}" fill="#0A0E1A"/>

  <g filter="url(#soft)" opacity="0.85">
      ${fan}
  </g>
  <g>
      ${fan}
  </g>

  <polygon points="${poly(bandPoints(INCOMING.band))}" fill="#FFFFFF" opacity="0.85" filter="url(#soft)"/>
  <polygon points="${poly(bandPoints(INCOMING.band))}" fill="#FFFFFF" opacity="0.9"/>

  <polygon points="${poly(SIDE)}" fill="url(#side)"/>
  <polygon points="${poly(FRONT)}" fill="url(#face)"/>

  <polygon points="${poly(bandPoints(INTERNAL.band))}" fill="#DCEBFF" opacity="0.55"/>

  <polygon points="${poly(FRONT)}" fill="none" stroke="#DCE6FF" stroke-opacity="0.85" stroke-width="2.5" stroke-linejoin="round"/>
  <polygon points="${poly(SIDE)}" fill="none" stroke="#AEC0EA" stroke-opacity="0.5" stroke-width="2" stroke-linejoin="round"/>

  <circle cx="${n(ENTRY[0])}" cy="${n(ENTRY[1])}" r="16" fill="url(#flare)"/>
  <circle cx="${n(EXIT[0])}" cy="${n(EXIT[1])}" r="20" fill="url(#flare)"/>
</svg>
`;
}

// --- PNG -------------------------------------------------------------------

function insidePoly(pts, x, y) {
  let hit = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i, i += 1) {
    const [xi, yi] = pts[i];
    const [xj, yj] = pts[j];
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) hit = !hit;
  }
  return hit;
}

/**
 * How brightly a band lights the point, 0..1.
 *
 * Gaussian across the width and falling off along the length, which is what
 * makes a beam look like light rather than a painted stripe.
 */
function bandLight(b, x, y) {
  const dx = x - b.origin[0];
  const dy = y - b.origin[1];
  const along = dx * b.dir[0] + dy * b.dir[1];
  if (along < 0 || along > b.length) return 0;
  const t = along / b.length;
  const across = Math.abs(dx * b.perp[0] + dy * b.perp[1]);
  const width = b.w0 + (b.w1 - b.w0) * t;
  const profile = Math.exp(-((across / width) ** 2) * 2.2);
  const fade = (1 - t) ** 0.7;
  const ramp = Math.min(1, t / 0.04);
  return profile * fade * ramp;
}

function flare(p, x, y, radius) {
  const d = Math.hypot(x - p[0], y - p[1]) / radius;
  return Math.exp(-d * d * 2.4);
}

function png() {
  const out = Buffer.alloc(SIZE * SIZE * 3);

  for (let py = 0; py < SIZE; py += 1) {
    for (let px = 0; px < SIZE; px += 1) {
      let r = 0;
      let g = 0;
      let b = 0;

      for (let sy = 0; sy < SS; sy += 1) {
        for (let sx = 0; sx < SS; sx += 1) {
          const x = px + (sx + 0.5) / SS;
          const y = py + (sy + 0.5) / SS;

          let c = [...BG];

          // Glass first: a faint body that the light is then added over, so the
          // beams read as passing through rather than being drawn on.
          if (insidePoly(SIDE, x, y)) {
            const t = (x - A[0]) / (C2[0] - A[0]);
            c = [c[0] + 44 * (1 - t * 0.5), c[1] + 54 * (1 - t * 0.5), c[2] + 84 * (1 - t * 0.4)];
          }
          if (insidePoly(FRONT, x, y)) {
            const t = (y - A[1]) / (C[1] - A[1]);
            c = [c[0] + 62 - 22 * t, c[1] + 74 - 24 * t, c[2] + 108 - 28 * t];
          }

          // Light is added, never blended: two beams crossing should be
          // brighter, which is the one thing alpha compositing gets wrong.
          const lights = [INCOMING, ...FAN];
          for (const l of lights) {
            const v = bandLight(l.band, x, y);
            if (v > 0) {
              c[0] += l.color[0] * v;
              c[1] += l.color[1] * v;
              c[2] += l.color[2] * v;
            }
          }
          if (insidePoly(FRONT, x, y)) {
            const v = bandLight(INTERNAL.band, x, y) * 0.85;
            c[0] += 220 * v;
            c[1] += 235 * v;
            c[2] += 255 * v;
          }

          for (const [p, radius, strength] of [
            [ENTRY, 20, 0.55],
            [EXIT, 26, 0.75],
          ]) {
            const v = flare(p, x, y, radius) * strength;
            c[0] += 255 * v;
            c[1] += 255 * v;
            c[2] += 255 * v;
          }

          // Edges, drawn as distance to each segment so they stay crisp.
          const edges = [
            [FRONT, 1.6, 210, 226, 255],
            [SIDE, 1.2, 150, 170, 220],
          ];
          for (const [shape, halfWidth, er, eg, eb] of edges) {
            for (let i = 0; i < shape.length; i += 1) {
              const p0 = shape[i];
              const p1 = shape[(i + 1) % shape.length];
              const vx = p1[0] - p0[0];
              const vy = p1[1] - p0[1];
              const len2 = vx * vx + vy * vy;
              let t = ((x - p0[0]) * vx + (y - p0[1]) * vy) / len2;
              t = Math.max(0, Math.min(1, t));
              const d = Math.hypot(x - (p0[0] + vx * t), y - (p0[1] + vy * t));
              if (d < halfWidth + 1) {
                const a = Math.max(0, Math.min(1, halfWidth + 1 - d));
                c[0] += (er - c[0]) * a * 0.9;
                c[1] += (eg - c[1]) * a * 0.9;
                c[2] += (eb - c[2]) * a * 0.9;
              }
            }
          }

          r += Math.min(255, c[0]);
          g += Math.min(255, c[1]);
          b += Math.min(255, c[2]);
        }
      }

      const n2 = SS * SS;
      const at = (py * SIZE + px) * 3;
      out[at] = Math.round(r / n2);
      out[at + 1] = Math.round(g / n2);
      out[at + 2] = Math.round(b / n2);
    }
  }

  return encodePng(out, SIZE, SIZE);
}

writeFileSync(process.argv[2], svg());
writeFileSync(process.argv[3], png());
