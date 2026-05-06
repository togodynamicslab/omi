import AVFoundation
import Flutter
import Foundation
import Speech

/// Bridge between Flutter and Apple's on-device SFSpeechRecognizer for the
/// pendant live-transcription preview. Dart pushes decoded PCM (16kHz mono
/// Int16) over a binary method channel; we wrap each chunk in an
/// `AVAudioPCMBuffer` and feed it into a `SFSpeechAudioBufferRecognitionRequest`.
/// Partial transcripts are pushed back to Dart via the same channel.
///
/// Per 2026-05-05 dogfood, this is the "Pendant → BLE → iOS STT" path —
/// UX-only signal, not the production transcription pipeline (that's
/// backend Deepgram). On-device flag preferred so audio doesn't leave the
/// device.
///
/// Method channel contract:
///   start({localeId: String, sampleRate: Int}) -> bool (whether session armed)
///   appendPcm({bytes: FlutterStandardTypedData}) -> nil
///   stop() -> nil
/// Callbacks (invoked on the Dart side):
///   onResult({text: String, isFinal: bool})
///   onError({code: String, message: String})
class SttBridge: NSObject, SFSpeechRecognizerDelegate {
  static let channelName = "com.nooto.stt_bridge"

  private let channel: FlutterMethodChannel
  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var inputFormat: AVAudioFormat?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: SttBridge.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  // MARK: - Method dispatch

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "BAD_ARGS", message: "expected map", details: nil))
        return
      }
      let localeId = args["localeId"] as? String ?? "en_US"
      let sampleRate = args["sampleRate"] as? Int ?? 16000
      start(localeId: localeId, sampleRate: sampleRate, result: result)
    case "appendPcm":
      guard let args = call.arguments as? [String: Any],
        let data = args["bytes"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "BAD_ARGS", message: "expected bytes", details: nil))
        return
      }
      appendPcm(int16Bytes: data.data)
      result(nil)
    case "stop":
      stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Lifecycle

  private func start(localeId: String, sampleRate: Int, result: @escaping FlutterResult) {
    // Tear down any previous session before starting a fresh one.
    stop()

    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        guard let self else {
          result(false)
          return
        }
        guard status == .authorized else {
          self.invokeError(code: "AUTH_DENIED", message: "speech recognition not authorized")
          result(false)
          return
        }
        self.armSession(localeId: localeId, sampleRate: sampleRate, result: result)
      }
    }
  }

  private func armSession(localeId: String, sampleRate: Int, result: @escaping FlutterResult) {
    let locale = Locale(identifier: localeId)
    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
      invokeError(code: "NO_RECOGNIZER", message: "no recognizer for locale \(localeId)")
      result(false)
      return
    }
    guard recognizer.isAvailable else {
      invokeError(code: "UNAVAILABLE", message: "recognizer unavailable for \(localeId)")
      result(false)
      return
    }
    recognizer.delegate = self

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if #available(iOS 13, *) {
      // Prefer on-device. Falls back to cloud automatically when the
      // user hasn't downloaded the on-device language pack.
      request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    }

    // Format we'll feed: 16kHz mono Int16 from the pendant after Opus decode.
    // SFSpeechRecognizer accepts most PCM formats; AVAudioFormat with the
    // matching sample rate + channel layout works as the canonical input.
    let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Double(sampleRate),
      channels: 1,
      interleaved: true
    )
    self.recognizer = recognizer
    self.request = request
    self.inputFormat = format

    self.task = recognizer.recognitionTask(with: request) { [weak self] r, error in
      guard let self else { return }
      if let r = r {
        self.invokeResult(text: r.bestTranscription.formattedString, isFinal: r.isFinal)
      }
      if let error = error {
        self.invokeError(code: "RECOGNITION", message: error.localizedDescription)
      }
    }

    result(true)
  }

  private func appendPcm(int16Bytes: Data) {
    guard let request = request, let format = inputFormat else { return }
    // Each Int16 sample = 2 bytes. AVAudioPCMBuffer expects frame count.
    let frameCount = AVAudioFrameCount(int16Bytes.count / 2)
    guard frameCount > 0 else { return }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
    buffer.frameLength = frameCount
    int16Bytes.withUnsafeBytes { rawBuf in
      guard let dst = buffer.int16ChannelData?[0] else { return }
      let src = rawBuf.bindMemory(to: Int16.self)
      for i in 0..<Int(frameCount) {
        dst[i] = src[i]
      }
    }
    request.append(buffer)
  }

  private func stop() {
    task?.cancel()
    task = nil
    request?.endAudio()
    request = nil
    recognizer?.delegate = nil
    recognizer = nil
    inputFormat = nil
  }

  // MARK: - Callbacks to Dart

  private func invokeResult(text: String, isFinal: Bool) {
    channel.invokeMethod("onResult", arguments: ["text": text, "isFinal": isFinal])
  }

  private func invokeError(code: String, message: String) {
    channel.invokeMethod("onError", arguments: ["code": code, "message": message])
  }

  // MARK: - SFSpeechRecognizerDelegate

  func speechRecognizer(_ recognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
    if !available {
      invokeError(code: "AVAILABILITY", message: "recognizer became unavailable")
    }
  }
}
