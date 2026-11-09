//! PNG encoding and resampling for screenshots.
//!
//! The plugin sends raw RGB (Zstd-compressed); the server owns the real
//! compressor, so it builds the PNG.

use std::io::{Read, Write};

/// Decompresses the plugin's Zstd frame.
pub fn zstd_decode(bytes: &[u8]) -> std::io::Result<Vec<u8>> {
    let mut decoder = ruzstd::decoding::StreamingDecoder::new(bytes).map_err(std::io::Error::other)?;
    let mut out = Vec::new();
    decoder.read_to_end(&mut out)?;
    Ok(out)
}

fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], payload: &[u8]) {
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    let start = out.len();
    out.extend_from_slice(kind);
    out.extend_from_slice(payload);
    let crc = crc32fast::hash(&out[start..]);
    out.extend_from_slice(&crc.to_be_bytes());
}

/// RGB triples to PNG: filter None per row, deflate level 6.
pub fn encode(rgb: &[u8], width: usize, height: usize) -> Result<Vec<u8>, String> {
    let stride = width * 3;
    if rgb.len() < stride * height {
        return Err(format!("pixel data is {} bytes, short of the {} needed for {width}x{height}", rgb.len(), stride * height));
    }
    let mut raw = Vec::with_capacity((stride + 1) * height);
    for row in rgb.chunks_exact(stride).take(height) {
        raw.push(0);
        raw.extend_from_slice(row);
    }
    let mut z = flate2::write::ZlibEncoder::new(Vec::with_capacity(raw.len() / 4), flate2::Compression::new(6));
    z.write_all(&raw).map_err(|e| e.to_string())?;
    let compressed = z.finish().map_err(|e| e.to_string())?;

    let mut header = Vec::with_capacity(13);
    header.extend_from_slice(&(width as u32).to_be_bytes());
    header.extend_from_slice(&(height as u32).to_be_bytes());
    header.extend_from_slice(&[8, 2, 0, 0, 0]);

    let mut out = Vec::with_capacity(compressed.len() + 64);
    out.extend_from_slice(&[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    chunk(&mut out, b"IHDR", &header);
    chunk(&mut out, b"IDAT", &compressed);
    chunk(&mut out, b"IEND", &[]);
    Ok(out)
}

struct Coverage {
    first: Vec<usize>,
    count: Vec<usize>,
    weight: Vec<f32>,
    taps: usize,
}

fn coverage(in_size: usize, out_size: usize) -> Coverage {
    let span = in_size as f64 / out_size as f64;
    let taps = span.ceil() as usize + 1;
    let mut c = Coverage { first: vec![0; out_size], count: vec![0; out_size], weight: vec![0.0; out_size * taps], taps };
    for out in 0..out_size {
        let from = out as f64 * span;
        let to = from + span;
        let low = from.floor() as usize;
        let high = (to.ceil() as usize).min(in_size);
        c.first[out] = low;
        c.count[out] = high - low;
        for source in low..high {
            let w = ((to.min(source as f64 + 1.0) - from.max(source as f64)).max(0.0) / span) as f32;
            c.weight[out * taps + source - low] = w;
        }
    }
    c
}

/// Area-weighted downscale to `out_width`; never scales up.
pub fn box_resample(rgb: &[u8], width: usize, height: usize, out_width: usize) -> (Vec<u8>, usize, usize) {
    if out_width >= width {
        return (rgb.to_vec(), width, height);
    }
    let out_height = ((height * out_width) as f64 / width as f64).round().max(1.0) as usize;
    let across = coverage(width, out_width);
    let mut wide = vec![0f32; out_width * height * 3];
    for row in 0..height {
        let in_row = row * width * 3;
        let out_row = row * out_width * 3;
        for out in 0..out_width {
            let (mut r, mut g, mut b) = (0f32, 0f32, 0f32);
            let mut at = in_row + across.first[out] * 3;
            let base = out * across.taps;
            for tap in 0..across.count[out] {
                let w = across.weight[base + tap];
                r += rgb[at] as f32 * w;
                g += rgb[at + 1] as f32 * w;
                b += rgb[at + 2] as f32 * w;
                at += 3;
            }
            let to = out_row + out * 3;
            wide[to] = r;
            wide[to + 1] = g;
            wide[to + 2] = b;
        }
    }
    let down = coverage(height, out_height);
    let row_len = out_width * 3;
    let mut sums = vec![0f32; row_len];
    let mut result = vec![0u8; row_len * out_height];
    for out in 0..out_height {
        sums.iter_mut().for_each(|s| *s = 0.0);
        let base = out * down.taps;
        for tap in 0..down.count[out] {
            let w = down.weight[base + tap];
            let in_row = (down.first[out] + tap) * row_len;
            for (s, v) in sums.iter_mut().zip(&wide[in_row..in_row + row_len]) {
                *s += v * w;
            }
        }
        for (dst, s) in result[out * row_len..(out + 1) * row_len].iter_mut().zip(&sums) {
            *dst = s.round().clamp(0.0, 255.0) as u8;
        }
    }
    (result, out_width, out_height)
}

/// Whole-factor nearest-neighbour enlargement: no detail added, none invented.
pub fn upscale_nearest(rgb: &[u8], width: usize, height: usize, factor: usize) -> (Vec<u8>, usize, usize) {
    if factor <= 1 {
        return (rgb.to_vec(), width, height);
    }
    let out_width = width * factor;
    let mut out = Vec::with_capacity(out_width * height * factor * 3);
    let mut row = Vec::with_capacity(out_width * 3);
    for y in 0..height {
        row.clear();
        for px in rgb[y * width * 3..(y + 1) * width * 3].as_chunks::<3>().0 {
            for _ in 0..factor {
                row.extend_from_slice(px);
            }
        }
        for _ in 0..factor {
            out.extend_from_slice(&row);
        }
    }
    (out, out_width, height * factor)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn png_roundtrip_header() {
        let png = encode(&[255, 0, 0, 0, 255, 0], 2, 1).unwrap();
        assert_eq!(&png[1..4], b"PNG");
    }

    #[test]
    fn resample_halves() {
        let rgb = vec![100u8; 4 * 2 * 3];
        let (out, w, h) = box_resample(&rgb, 4, 2, 2);
        assert_eq!((w, h), (2, 1));
        assert!(out.iter().all(|v| *v == 100));
    }
}
