//! Linux-native OCR via libtesseract.
//!
//! Tesseract is installed system-wide (`apt install tesseract-ocr
//! libtesseract-dev`); language data (`tesseract-ocr-eng`,
//! `tesseract-ocr-por`) ships separately. We don't bundle any model files —
//! that's the whole point of using the system OCR.
//!
//! Engine reuse: under continuous capture, a fresh `Tesseract::new` per call
//! leaks ~15-20MB of libtesseract internal state per call (the binding's
//! Drop calls End() not Clear(), and on libtesseract 5.x not all language-
//! model state is released). We keep a single engine in a global `Mutex`
//! and reuse it. `Tesseract` is `!Sync` so the mutex serializes calls; OCR
//! is already single-threaded in our pipeline (one `spawn_blocking` per
//! screenshot) so this isn't a throughput regression.

use std::sync::{Mutex, OnceLock};

use crate::ocr::{OcrTextBlock, OcrTextResult};
use tesseract::Tesseract;

/// Global Tesseract engine. Initialized lazily on first OCR call.
///
/// Held inside an `Option` so that we can `take()` it for builder-style
/// methods (`set_image_from_mem`, `recognize` consume `self`) and put the
/// resulting instance back. If a method ever fails partway through, we
/// leave the slot `None`; the next call re-initializes from scratch.
static OCR_ENGINE: OnceLock<Mutex<Option<Tesseract>>> = OnceLock::new();

fn engine_lock() -> &'static Mutex<Option<Tesseract>> {
    OCR_ENGINE.get_or_init(|| Mutex::new(None))
}

fn init_engine() -> Result<Tesseract, String> {
    Tesseract::new(None, Some("eng+por")).map_err(|e| format!("Tesseract init failed: {e}"))
}

/// Run Tesseract OCR on a JPEG buffer and return blocks + concatenated text.
///
/// Reuses a single global engine across calls. Per-line bounding boxes
/// come from Tesseract's TSV output (level 4 = textline). We aggregate
/// the child word rows to compute the line text and an average confidence.
pub fn extract_text(jpeg_data: &[u8]) -> Result<OcrTextResult, String> {
    let mutex = engine_lock();
    let mut guard = mutex
        .lock()
        .map_err(|e| format!("Tesseract engine mutex poisoned: {e}"))?;

    // Pull the engine out of the slot so we can drive its builder-style
    // methods. If anything fails, we leave the slot `None` and the next
    // caller reinitializes — better than poisoning the whole pipeline.
    let mut tess = match guard.take() {
        Some(t) => t,
        None => init_engine()?,
    };

    tess = tess
        .set_image_from_mem(jpeg_data)
        .map_err(|e| format!("Tesseract set_image_from_mem failed: {e}"))?
        .recognize()
        .map_err(|e| format!("Tesseract recognize failed: {e}"))?;

    let full_text = tess
        .get_text()
        .map_err(|e| format!("Tesseract get_text failed: {e}"))?;

    let tsv = tess
        .get_tsv_text(0)
        .map_err(|e| format!("Tesseract get_tsv_text failed: {e}"))?;

    // Park the engine back for the next call. If we panicked above, the
    // slot stays `None` (we already `take()`'d it) and the next call
    // re-inits — no risk of leaving the engine in an inconsistent state.
    *guard = Some(tess);
    drop(guard);

    let blocks = parse_line_blocks(&tsv);

    tracing::debug!(
        "[ocr_tesseract] {} bytes JPEG → {} line blocks",
        jpeg_data.len(),
        blocks.len()
    );

    Ok(OcrTextResult {
        full_text: full_text.trim_end().to_string(),
        blocks,
    })
}

/// Parse Tesseract TSV output and emit one block per textline.
///
/// TSV columns: `level page block para line word left top width height conf text`.
/// Level 4 = textline (bbox covers the whole line; text column is empty).
/// Level 5 = word (text + per-word confidence). We walk in order, opening
/// a new line at each level-4 row and folding subsequent level-5 rows into
/// it until the next level-4 row appears.
fn parse_line_blocks(tsv: &str) -> Vec<OcrTextBlock> {
    let mut out: Vec<OcrTextBlock> = Vec::new();
    let mut current: Option<LineAccum> = None;

    for row in tsv.lines().skip(1) {
        let c: Vec<&str> = row.split('\t').collect();
        if c.len() < 12 {
            continue;
        }
        let level = c[0];
        let left: i32 = c[6].parse().unwrap_or(0);
        let top: i32 = c[7].parse().unwrap_or(0);
        let width: i32 = c[8].parse().unwrap_or(0);
        let height: i32 = c[9].parse().unwrap_or(0);

        match level {
            "4" => {
                if let Some(line) = current.take() {
                    if let Some(block) = line.into_block() {
                        out.push(block);
                    }
                }
                current = Some(LineAccum::new(left, top, width, height));
            }
            "5" => {
                // Tesseract emits confidence as a float ("92.87"), not an int.
                // Round to i32 so downstream confidence math stays integer.
                let conf: i32 = c[10].parse::<f32>().map(|f| f.round() as i32).unwrap_or(-1);
                let text = c[11];
                if conf >= 0 && !text.is_empty() {
                    if let Some(line) = current.as_mut() {
                        line.push_word(text, conf);
                    }
                }
            }
            _ => {}
        }
    }

    if let Some(line) = current.take() {
        if let Some(block) = line.into_block() {
            out.push(block);
        }
    }

    out
}

struct LineAccum {
    bbox: [u32; 4],
    words: Vec<String>,
    conf_sum: i32,
    conf_count: i32,
}

impl LineAccum {
    fn new(left: i32, top: i32, width: i32, height: i32) -> Self {
        let x_min = left.max(0) as u32;
        let y_min = top.max(0) as u32;
        let x_max = (left + width).max(0) as u32;
        let y_max = (top + height).max(0) as u32;
        Self {
            bbox: [x_min, y_min, x_max, y_max],
            words: Vec::new(),
            conf_sum: 0,
            conf_count: 0,
        }
    }

    fn push_word(&mut self, text: &str, conf: i32) {
        self.words.push(text.to_string());
        self.conf_sum += conf;
        self.conf_count += 1;
    }

    fn into_block(self) -> Option<OcrTextBlock> {
        if self.words.is_empty() {
            return None;
        }
        let text = self.words.join(" ");
        if text.trim().is_empty() {
            return None;
        }
        let confidence = if self.conf_count > 0 {
            (self.conf_sum as f32 / self.conf_count as f32) / 100.0
        } else {
            0.0
        };
        Some(OcrTextBlock {
            text,
            confidence,
            bbox: self.bbox,
        })
    }
}
