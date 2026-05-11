//! Windows system-audio capture via WASAPI loopback.
//!
//! Opens the default render endpoint in shared loopback mode, polls the
//! `IAudioCaptureClient` every 50 ms, downmixes to mono and resamples to
//! 16 kHz i16 PCM — the same shape Mac / Linux callers expect.
//!
//! Drop the returned `SystemAudioCapture` to stop the capture; the worker
//! thread observes the atomic and unwinds COM cleanly.

#![cfg(target_os = "windows")]

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use tokio::sync::mpsc;
use windows::core::{Interface, GUID};
use windows::Win32::Foundation::WAIT_OBJECT_0;
use windows::Win32::Media::Audio::{
    eConsole, eRender, IAudioCaptureClient, IAudioClient, IMMDeviceEnumerator, MMDeviceEnumerator,
    AUDCLNT_BUFFERFLAGS_SILENT, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
    AUDCLNT_STREAMFLAGS_LOOPBACK, WAVEFORMATEX, WAVEFORMATEXTENSIBLE,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, CLSCTX_ALL,
    COINIT_MULTITHREADED,
};
use windows::Win32::System::Threading::{CreateEventW, WaitForSingleObject};

// Constants not re-exported in the `windows` crate slice we depend on —
// safer to define them inline than to chase another feature flag.
const KSDATAFORMAT_SUBTYPE_PCM: GUID =
    GUID::from_u128(0x00000001_0000_0010_8000_00aa00389b71);
const KSDATAFORMAT_SUBTYPE_IEEE_FLOAT: GUID =
    GUID::from_u128(0x00000003_0000_0010_8000_00aa00389b71);
const WAVE_FORMAT_PCM: u32 = 0x0001;
const WAVE_FORMAT_IEEE_FLOAT: u32 = 0x0003;
const WAVE_FORMAT_EXTENSIBLE: u32 = 0xFFFE;

const TARGET_RATE: u32 = 16_000;
/// 100 ms in 100-ns reftime units — gives the audio engine room to breathe
/// while keeping latency low enough for live transcription.
const BUFFER_REFTIME: i64 = 1_000_000;
/// How long the worker waits for the WASAPI event before re-checking the
/// stop flag. Keeps shutdown latency under ~100 ms even when no audio is
/// playing.
const WAIT_TIMEOUT_MS: u32 = 100;

pub struct SystemAudioCapture {
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

// SAFETY: the inner thread handle and atomic flag are both Send/Sync;
// the WASAPI COM objects live entirely inside the worker thread.
unsafe impl Send for SystemAudioCapture {}

impl SystemAudioCapture {
    pub fn start(tx: mpsc::Sender<Vec<i16>>) -> Result<Self, String> {
        let stop = Arc::new(AtomicBool::new(false));
        let stop_for_thread = stop.clone();

        let thread = std::thread::Builder::new()
            .name("wasapi-loopback".into())
            .spawn(move || {
                if let Err(e) = run_capture(tx, stop_for_thread) {
                    tracing::warn!("[wasapi-loopback] worker exited: {}", e);
                } else {
                    tracing::info!("[wasapi-loopback] worker stopped cleanly");
                }
            })
            .map_err(|e| format!("spawn loopback thread: {}", e))?;

        Ok(Self {
            stop,
            thread: Some(thread),
        })
    }
}

impl Drop for SystemAudioCapture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// What the device's mix format encodes. Determines how we decode samples
/// into f32 for downmix + resample.
#[derive(Debug, Clone, Copy)]
enum SampleEncoding {
    Float32,
    Pcm16,
    Pcm32,
}

fn run_capture(tx: mpsc::Sender<Vec<i16>>, stop: Arc<AtomicBool>) -> Result<(), String> {
    unsafe {
        // Initialise COM for the lifetime of this thread. Using MTA so the
        // WASAPI calls don't pin us to a single message-pump thread.
        let hr = CoInitializeEx(None, COINIT_MULTITHREADED);
        if hr.is_err() {
            return Err(format!("CoInitializeEx failed: {:?}", hr));
        }

        let result = capture_inner(tx, stop);

        CoUninitialize();
        result
    }
}

unsafe fn capture_inner(
    tx: mpsc::Sender<Vec<i16>>,
    stop: Arc<AtomicBool>,
) -> Result<(), String> {
    let enumerator: IMMDeviceEnumerator =
        CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
            .map_err(|e| format!("CoCreateInstance(MMDeviceEnumerator): {:?}", e))?;

    let device = enumerator
        .GetDefaultAudioEndpoint(eRender, eConsole)
        .map_err(|e| format!("GetDefaultAudioEndpoint(eRender, eConsole): {:?}", e))?;

    let client: IAudioClient = device
        .Activate(CLSCTX_ALL, None)
        .map_err(|e| format!("device.Activate(IAudioClient): {:?}", e))?;

    // Mix format = whatever Windows is currently mixing on this endpoint
    // (typically 48 kHz / 2 ch / 32-bit float on Win10+).
    let mix_format_ptr = client
        .GetMixFormat()
        .map_err(|e| format!("GetMixFormat: {:?}", e))?;
    if mix_format_ptr.is_null() {
        return Err("GetMixFormat returned null".to_string());
    }

    // WAVEFORMATEX is `#[repr(packed)]`, so taking field references would
    // be unsound. Read an aligned copy for our own use; pass the original
    // pointer to `Initialize`.
    let format = std::ptr::read_unaligned(mix_format_ptr);
    let sample_rate = format.nSamplesPerSec;
    let channels = format.nChannels as usize;
    let bits = format.wBitsPerSample;
    let block_align = format.nBlockAlign as usize;
    let format_tag = format.wFormatTag;
    let cb_size = format.cbSize;

    let encoding = detect_encoding(format_tag, bits, cb_size, mix_format_ptr).ok_or_else(|| {
        format!(
            "unsupported mix format: tag={} bits={} channels={}",
            format_tag, bits, channels
        )
    })?;

    tracing::info!(
        "[wasapi-loopback] mix format: {} Hz, {} ch, {} bits, encoding={:?}",
        sample_rate,
        channels,
        bits,
        encoding
    );

    let event = CreateEventW(None, false, false, None)
        .map_err(|e| format!("CreateEventW: {:?}", e))?;

    if let Err(e) = client.Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
        BUFFER_REFTIME,
        0,
        mix_format_ptr,
        None,
    ) {
        CoTaskMemFree(Some(mix_format_ptr as _));
        return Err(format!("client.Initialize: {:?}", e));
    }

    if let Err(e) = client.SetEventHandle(event) {
        CoTaskMemFree(Some(mix_format_ptr as _));
        return Err(format!("client.SetEventHandle: {:?}", e));
    }

    let capture_client: IAudioCaptureClient = match client.GetService() {
        Ok(c) => c,
        Err(e) => {
            CoTaskMemFree(Some(mix_format_ptr as _));
            return Err(format!("GetService<IAudioCaptureClient>: {:?}", e));
        }
    };

    if let Err(e) = client.Start() {
        CoTaskMemFree(Some(mix_format_ptr as _));
        return Err(format!("client.Start: {:?}", e));
    }

    while !stop.load(Ordering::SeqCst) {
        // Wake on the audio engine event or every WAIT_TIMEOUT_MS so we
        // can observe the stop flag even when the user has no audio
        // playing through the speakers.
        let wait = WaitForSingleObject(event, WAIT_TIMEOUT_MS);
        if wait != WAIT_OBJECT_0 && wait.0 != 0x102 {
            // 0x102 = WAIT_TIMEOUT — expected when no audio is playing.
            tracing::warn!("[wasapi-loopback] WaitForSingleObject returned {:?}", wait);
        }

        loop {
            let packet_size = match capture_client.GetNextPacketSize() {
                Ok(n) => n,
                Err(_) => break,
            };
            if packet_size == 0 {
                break;
            }

            let mut buffer_ptr: *mut u8 = std::ptr::null_mut();
            let mut frames_available: u32 = 0;
            let mut flags: u32 = 0;
            if capture_client
                .GetBuffer(
                    &mut buffer_ptr,
                    &mut frames_available,
                    &mut flags,
                    None,
                    None,
                )
                .is_err()
            {
                break;
            }

            if frames_available > 0 {
                let total_bytes = frames_available as usize * block_align;
                let bytes = std::slice::from_raw_parts(buffer_ptr, total_bytes);
                let is_silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32) != 0;

                let mono = downmix_to_mono_i16(bytes, encoding, channels, block_align, is_silent);
                let resampled = resample_linear(&mono, sample_rate, TARGET_RATE);

                if !resampled.is_empty() {
                    // Drop on full instead of blocking — matches the
                    // "real-time HAL callback drops on full" comment in
                    // the macOS path.
                    let _ = tx.try_send(resampled);
                }
            }

            let _ = capture_client.ReleaseBuffer(frames_available);
        }
    }

    let _ = client.Stop();
    CoTaskMemFree(Some(mix_format_ptr as _));
    Ok(())
}

/// Decode `WAVEFORMATEX` / `WAVEFORMATEXTENSIBLE` into one of the three
/// shapes WASAPI shared-mode actually emits in the wild on Windows 10/11.
///
/// Caller passes `wFormatTag`, `wBitsPerSample` and `cbSize` already read
/// out of the packed header, plus the original pointer — needed only when
/// `tag == WAVE_FORMAT_EXTENSIBLE` so we can read the trailing SubFormat
/// GUID via `read_unaligned`.
unsafe fn detect_encoding(
    tag: u16,
    bits: u16,
    cb_size: u16,
    format_ptr: *const WAVEFORMATEX,
) -> Option<SampleEncoding> {
    let tag32 = tag as u32;

    if tag32 == WAVE_FORMAT_IEEE_FLOAT && bits == 32 {
        return Some(SampleEncoding::Float32);
    }
    if tag32 == WAVE_FORMAT_PCM {
        return match bits {
            16 => Some(SampleEncoding::Pcm16),
            32 => Some(SampleEncoding::Pcm32),
            _ => None,
        };
    }

    if tag32 == WAVE_FORMAT_EXTENSIBLE && cb_size >= 22 {
        // Read the extensible payload from the same address as the base
        // header; the extra 22 bytes after `cbSize` carry SubFormat etc.
        // Pull the GUID out via `addr_of!` + `read_unaligned` since
        // `WAVEFORMATEXTENSIBLE` is `#[repr(packed)]` and direct field
        // access would be a compile error.
        let ext_ptr = format_ptr as *const WAVEFORMATEXTENSIBLE;
        let sub_format: GUID = std::ptr::addr_of!((*ext_ptr).SubFormat).read_unaligned();
        if sub_format == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT && bits == 32 {
            return Some(SampleEncoding::Float32);
        }
        if sub_format == KSDATAFORMAT_SUBTYPE_PCM {
            return match bits {
                16 => Some(SampleEncoding::Pcm16),
                32 => Some(SampleEncoding::Pcm32),
                _ => None,
            };
        }
    }

    None
}

/// Decode each interleaved frame into a single mono i16 sample.
/// `block_align` is the byte stride between consecutive frames (channels ×
/// bytes_per_sample, plus any padding the device declares).
fn downmix_to_mono_i16(
    bytes: &[u8],
    encoding: SampleEncoding,
    channels: usize,
    block_align: usize,
    is_silent: bool,
) -> Vec<i16> {
    if block_align == 0 || channels == 0 {
        return Vec::new();
    }
    let frames = bytes.len() / block_align;

    if is_silent {
        return vec![0i16; frames];
    }

    let bytes_per_sample = match encoding {
        SampleEncoding::Float32 | SampleEncoding::Pcm32 => 4,
        SampleEncoding::Pcm16 => 2,
    };

    let mut out = Vec::with_capacity(frames);
    for f in 0..frames {
        let frame_off = f * block_align;
        let mut sum = 0.0f32;
        for ch in 0..channels {
            let off = frame_off + ch * bytes_per_sample;
            if off + bytes_per_sample > bytes.len() {
                break;
            }
            let normalized = match encoding {
                SampleEncoding::Float32 => {
                    let arr: [u8; 4] = bytes[off..off + 4].try_into().unwrap();
                    f32::from_le_bytes(arr)
                }
                SampleEncoding::Pcm16 => {
                    let arr: [u8; 2] = bytes[off..off + 2].try_into().unwrap();
                    i16::from_le_bytes(arr) as f32 / i16::MAX as f32
                }
                SampleEncoding::Pcm32 => {
                    let arr: [u8; 4] = bytes[off..off + 4].try_into().unwrap();
                    i32::from_le_bytes(arr) as f32 / i32::MAX as f32
                }
            };
            sum += normalized;
        }
        let avg = (sum / channels as f32).clamp(-1.0, 1.0);
        out.push((avg * i16::MAX as f32) as i16);
    }

    out
}

/// Same linear interpolator the mic path uses (capture.rs::resample_linear),
/// duplicated here so this module stays self-contained — both versions are
/// trivial and identical in behaviour.
fn resample_linear(input: &[i16], from_rate: u32, to_rate: u32) -> Vec<i16> {
    if from_rate == to_rate || input.is_empty() {
        return input.to_vec();
    }
    let ratio = to_rate as f64 / from_rate as f64;
    let output_len = ((input.len() as f64) * ratio) as usize;
    if output_len == 0 {
        return Vec::new();
    }

    let mut output = Vec::with_capacity(output_len);
    let last = input.len() - 1;
    for i in 0..output_len {
        let src = (i as f64) / ratio;
        let lo = src.floor() as usize;
        let hi = (lo + 1).min(last);
        let t = (src - lo as f64) as f32;
        let s = input[lo.min(last)] as f32 * (1.0 - t) + input[hi] as f32 * t;
        output.push(s as i16);
    }
    output
}
