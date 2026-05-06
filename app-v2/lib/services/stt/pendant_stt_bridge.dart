import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin wrapper around the iOS-side `SttBridge` (see
/// `ios/Runner/SttBridge.swift`).
///
/// Per 2026-05-05 dogfood, the live-transcription preview takes the
/// "Pendant → BLE Opus → on-device iOS STT" path:
///
/// 1. Caller pushes 16-bit PCM (decoded from Opus) via [appendPcm].
/// 2. iOS native code wraps each chunk into an `AVAudioPCMBuffer` and
///    feeds `SFSpeechAudioBufferRecognitionRequest`.
/// 3. Partial transcripts arrive on [results] as they're recognized.
///
/// iOS-only for now. On Android the bridge is a no-op (Android's
/// SpeechRecognizer doesn't take external buffers; a separate engine
/// like Vosk would be needed). [start] returns false on non-iOS.
class PendantSttBridge {
  PendantSttBridge() {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  static const MethodChannel _channel = MethodChannel('com.nooto.stt_bridge');

  final StreamController<PendantSttResult> _results = StreamController<PendantSttResult>.broadcast();

  /// Stream of partial / final transcripts pushed back from iOS. Emits
  /// `(text, isFinal)` tuples — UI typically just reads the latest.
  Stream<PendantSttResult> get results => _results.stream;

  /// Arms a recognition session for [localeId] (e.g. `en_US`, `pt_BR`)
  /// at the given [sampleRate]. Pendant audio is typically 16kHz Opus
  /// → 16kHz Int16 PCM after decode. Returns true if the session armed
  /// successfully. False if not iOS, no recognizer, or auth denied.
  Future<bool> start({required String localeId, int sampleRate = 16000}) async {
    if (!_isSupportedPlatform) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('start', {
        'localeId': localeId,
        'sampleRate': sampleRate,
      });
      return ok ?? false;
    } on PlatformException catch (e) {
      debugPrint('[PendantSttBridge] start failed: $e');
      return false;
    }
  }

  /// Push a chunk of 16-bit signed PCM samples. Caller is responsible
  /// for decoding Opus to PCM before invoking this. Bytes are passed as
  /// raw `Uint8List` — `[lo0, hi0, lo1, hi1, ...]` little-endian Int16.
  Future<void> appendPcm(Uint8List bytes) async {
    if (!_isSupportedPlatform) return;
    if (bytes.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('appendPcm', {'bytes': bytes});
    } on PlatformException catch (e) {
      debugPrint('[PendantSttBridge] appendPcm failed: $e');
    }
  }

  /// Stop the recognition session and release resources. Idempotent.
  Future<void> stop() async {
    if (!_isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (e) {
      debugPrint('[PendantSttBridge] stop failed: $e');
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _results.close();
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onResult':
        final args = (call.arguments as Map?) ?? const {};
        final text = (args['text'] as String?) ?? '';
        final isFinal = (args['isFinal'] as bool?) ?? false;
        _results.add(PendantSttResult(text: text, isFinal: isFinal));
        break;
      case 'onError':
        final args = (call.arguments as Map?) ?? const {};
        final code = (args['code'] as String?) ?? 'UNKNOWN';
        final message = (args['message'] as String?) ?? '';
        debugPrint('[PendantSttBridge] iOS error $code: $message');
        break;
    }
    return null;
  }

  bool get _isSupportedPlatform => defaultTargetPlatform == TargetPlatform.iOS;
}

class PendantSttResult {
  const PendantSttResult({required this.text, required this.isFinal});
  final String text;
  final bool isFinal;
}
