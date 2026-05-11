//! Windows-native OCR via `Windows.Media.Ocr` (WinRT).
//!
//! Same role as `ocr_vision.rs` for macOS: avoids shipping the PaddleOCR
//! ONNX models and the `ort` runtime on Windows. PaddleOCR was eating
//! ~hundreds of MB of RAM and a steady chunk of CPU on every Rewind frame
//! because each `detect` call ran a CNN through `ort`. Windows.Media.Ocr is
//! in-process, GPU-accelerated when possible, ships with the OS, and uses
//! the same recognizer Microsoft Edge / Office use under the hood.
//!
//! Bounding boxes are returned in pixel coordinates (top-left origin) of the
//! decoded `SoftwareBitmap`, which matches the source JPEG dimensions, so we
//! don't need the bottom-left → top-left flip Vision requires.
//!
//! Threading: WinRT async ops only return a usable result if a COM apartment
//! has been initialized on the calling thread. We initialize MTA on first
//! use per worker thread and then re-use it (subsequent calls on the same
//! thread are a no-op return).

use crate::ocr::{OcrTextBlock, OcrTextResult};
use std::cell::Cell;
use windows::core::HSTRING;
use windows::Globalization::Language;
use windows::Graphics::Imaging::BitmapDecoder;
use windows::Media::Ocr::OcrEngine;
use windows::Storage::Streams::{DataWriter, InMemoryRandomAccessStream};
use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};

thread_local! {
    /// We call `CoInitializeEx(MTA)` once per worker thread. WinRT async
    /// `.get()` deadlocks on STA threads, and tokio's `spawn_blocking` pool
    /// is uninitialized by default.
    static COM_INITIALIZED: Cell<bool> = const { Cell::new(false) };
}

fn ensure_mta() {
    COM_INITIALIZED.with(|flag| {
        if !flag.get() {
            // SAFETY: CoInitializeEx is safe to call repeatedly. RPC_E_CHANGED_MODE
            // means the thread is already STA — we tolerate it (`.ok()`) and proceed;
            // worst case the async `.get()` may hop apartments, which is fine.
            unsafe {
                let _ = CoInitializeEx(None, COINIT_MULTITHREADED).ok();
            }
            flag.set(true);
        }
    });
}

/// Run Windows.Media.Ocr on a JPEG buffer and return blocks + concatenated text.
pub fn extract_text(jpeg_data: &[u8]) -> Result<OcrTextResult, String> {
    ensure_mta();

    // --- Wrap JPEG bytes in an IRandomAccessStream ---
    let stream = InMemoryRandomAccessStream::new()
        .map_err(|e| format!("InMemoryRandomAccessStream::new failed: {}", e))?;
    {
        let writer = DataWriter::CreateDataWriter(&stream)
            .map_err(|e| format!("DataWriter::CreateDataWriter failed: {}", e))?;
        writer
            .WriteBytes(jpeg_data)
            .map_err(|e| format!("DataWriter::WriteBytes failed: {}", e))?;
        writer
            .StoreAsync()
            .and_then(|op| op.get())
            .map_err(|e| format!("DataWriter::StoreAsync failed: {}", e))?;
        writer
            .FlushAsync()
            .and_then(|op| op.get())
            .map_err(|e| format!("DataWriter::FlushAsync failed: {}", e))?;
        // Detach so closing the DataWriter doesn't dispose the stream.
        let _ = writer.DetachStream();
    }
    stream
        .Seek(0)
        .map_err(|e| format!("stream.Seek failed: {}", e))?;

    // --- Decode JPEG → SoftwareBitmap ---
    let decoder = BitmapDecoder::CreateAsync(&stream)
        .and_then(|op| op.get())
        .map_err(|e| format!("BitmapDecoder::CreateAsync failed: {}", e))?;

    let bitmap = decoder
        .GetSoftwareBitmapAsync()
        .and_then(|op| op.get())
        .map_err(|e| format!("BitmapDecoder::GetSoftwareBitmapAsync failed: {}", e))?;

    let img_w = bitmap
        .PixelWidth()
        .map_err(|e| format!("SoftwareBitmap.PixelWidth failed: {}", e))? as u32;
    let img_h = bitmap
        .PixelHeight()
        .map_err(|e| format!("SoftwareBitmap.PixelHeight failed: {}", e))? as u32;

    // Windows.Media.Ocr enforces a 50–2600px hard limit per side. Above that
    // RecognizeAsync throws E_INVALIDARG. Our screenshots can be 4K+ on
    // multi-monitor setups, so reject early with a clear error — `extract_text`
    // is called from a `spawn_blocking` task and the caller logs the message.
    const MAX_SIDE: u32 = 2600;
    if img_w > MAX_SIDE || img_h > MAX_SIDE {
        return Err(format!(
            "Windows.Media.Ocr image too large: {}x{} (max {}px per side)",
            img_w, img_h, MAX_SIDE
        ));
    }

    // --- Build OcrEngine ---
    // Prefer the user's profile languages so tray-OS-locale gets respected.
    // Falls back to en-US, then pt-BR, mirroring what the macOS Vision path
    // requests. On a fresh Windows 11 install both packs are usually present.
    let engine = create_engine()?;

    // --- Recognize ---
    let result = engine
        .RecognizeAsync(&bitmap)
        .and_then(|op| op.get())
        .map_err(|e| format!("OcrEngine.RecognizeAsync failed: {}", e))?;

    let lines = result
        .Lines()
        .map_err(|e| format!("OcrResult.Lines failed: {}", e))?;
    let line_count = lines.Size().unwrap_or(0);

    let mut blocks: Vec<OcrTextBlock> = Vec::with_capacity(line_count as usize);
    let mut texts: Vec<String> = Vec::with_capacity(line_count as usize);

    for line in lines.into_iter() {
        let text_h = match line.Text() {
            Ok(t) => t,
            Err(_) => continue,
        };
        let text = text_h.to_string();
        if text.trim().is_empty() {
            continue;
        }

        // OcrLine has no bbox — derive one as the union of word boxes. Words
        // are absent on languages without word segmentation (CJK), in which
        // case we fall back to a zero-rect (TS layer treats this as an
        // un-grounded block).
        let mut x_min = f32::INFINITY;
        let mut y_min = f32::INFINITY;
        let mut x_max = f32::NEG_INFINITY;
        let mut y_max = f32::NEG_INFINITY;

        if let Ok(words) = line.Words() {
            for word in words.into_iter() {
                if let Ok(rect) = word.BoundingRect() {
                    x_min = x_min.min(rect.X);
                    y_min = y_min.min(rect.Y);
                    x_max = x_max.max(rect.X + rect.Width);
                    y_max = y_max.max(rect.Y + rect.Height);
                }
            }
        }

        let bbox = if x_min.is_finite() && x_max.is_finite() && x_max > x_min && y_max > y_min {
            [
                clamp_u32(x_min, img_w),
                clamp_u32(y_min, img_h),
                clamp_u32(x_max, img_w),
                clamp_u32(y_max, img_h),
            ]
        } else {
            [0, 0, 0, 0]
        };

        // Windows.Media.Ocr doesn't surface per-line/word confidence. Report
        // 1.0 so the TS layer's confidence-weighted ranking treats every
        // recognized line as trusted (same effective behavior as the macOS
        // path when Vision returns confidence=1.0 for clean UI text).
        blocks.push(OcrTextBlock {
            text: text.clone(),
            confidence: 1.0,
            bbox,
        });
        texts.push(text);
    }

    let full_text = texts.join("\n");

    // INFO: visible by default — count, total chars, and a truncated sample
    // of the first non-empty line so the user can eyeball whether the
    // recognizer is reading the actual screen content. Truncated to 120
    // chars to avoid spamming the terminal with full screen dumps.
    let sample = blocks
        .first()
        .map(|b| {
            let s: String = b.text.chars().take(120).collect();
            if b.text.chars().count() > 120 { format!("{}…", s) } else { s }
        })
        .unwrap_or_default();
    tracing::info!(
        "[ocr_windows] {}x{} → {} lines, {} chars | first: {:?}",
        img_w,
        img_h,
        blocks.len(),
        full_text.len(),
        sample,
    );

    // DEBUG: per-block bbox + text. Enable with
    //   $env:RUST_LOG="tauri_plugin_screen_capture=debug"
    // before `pnpm tauri dev` to inspect grounding accuracy.
    if tracing::enabled!(tracing::Level::DEBUG) {
        for (i, b) in blocks.iter().enumerate() {
            let preview: String = b.text.chars().take(80).collect();
            tracing::debug!(
                "[ocr_windows]   #{:02} bbox=[{},{},{},{}] ({}x{}) text={:?}",
                i,
                b.bbox[0],
                b.bbox[1],
                b.bbox[2],
                b.bbox[3],
                b.bbox[2].saturating_sub(b.bbox[0]),
                b.bbox[3].saturating_sub(b.bbox[1]),
                preview,
            );
        }
    }

    Ok(OcrTextResult { full_text, blocks })
}

/// Build an `OcrEngine` honoring user-profile languages, falling back to
/// en-US then pt-BR. Returns an error only if no usable engine could be made
/// (no recognizer language packs installed).
fn create_engine() -> Result<OcrEngine, String> {
    // `TryCreate*` methods in WinRT return null when no recognizer is
    // available; windows-rs surfaces that as `Err(E_POINTER)`. So a plain
    // `Ok(engine)` here is enough — we don't need to null-check.
    if let Ok(engine) = OcrEngine::TryCreateFromUserProfileLanguages() {
        return Ok(engine);
    }

    for tag in ["en-US", "pt-BR"] {
        if let Ok(lang) = Language::CreateLanguage(&HSTRING::from(tag)) {
            if OcrEngine::IsLanguageSupported(&lang).unwrap_or(false) {
                if let Ok(engine) = OcrEngine::TryCreateFromLanguage(&lang) {
                    return Ok(engine);
                }
            }
        }
    }

    Err("No Windows.Media.Ocr recognizer is installed (install a language pack with OCR support, e.g. en-US)".to_string())
}

fn clamp_u32(v: f32, max: u32) -> u32 {
    if !v.is_finite() || v <= 0.0 {
        return 0;
    }
    let r = v.round();
    if r >= max as f32 {
        max
    } else {
        r as u32
    }
}
