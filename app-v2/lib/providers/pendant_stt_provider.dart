import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

import 'package:nooto_v2/audio/codec.dart';
import 'package:nooto_v2/services/ble/omi_pendant.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/services/stt/pendant_stt_bridge.dart';

/// On-device live-transcription provider for the pendant audio stream.
///
/// Pipeline (per 2026-05-05 dogfood, "Pendant → BLE → iOS STT"):
///
///     OmiPendant.audioBytes (Opus chunks)
///       → SimpleOpusDecoder (Dart, opus_dart + opus_flutter native libs)
///       → 16-bit Int16 PCM samples
///       → PendantSttBridge.appendPcm (method channel)
///       → Swift SttBridge → SFSpeechAudioBufferRecognitionRequest
///       → partial transcripts
///       → liveTranscript: ValueNotifier<String>
///
/// UX-only signal — the production transcription pipeline still runs
/// server-side off the same Opus packets. iOS-only; on other platforms
/// [liveTranscript] stays empty.
///
/// Wiring: a `ChangeNotifierProxyProvider2<PendantProvider, LocaleProvider>`
/// in main.dart drives [onPendantStateChanged] (start/stop on `live`)
/// and [onLocaleChanged] (`en_US` vs `pt_BR`).
class PendantSttProvider extends ChangeNotifier {
  PendantSttProvider({OmiPendant? pendant, PendantSttBridge? bridge})
    : _pendant = pendant ?? OmiPendant.instance,
      _bridge = bridge ?? PendantSttBridge() {
    _resultsSub = _bridge.results.listen(_onResult);
  }

  final OmiPendant _pendant;
  final PendantSttBridge _bridge;

  StreamSubscription<List<int>>? _audioSub;
  StreamSubscription<PendantSttResult>? _resultsSub;

  bool _isActive = false;
  bool _opusInitialized = false;
  String? _currentLocaleId = 'en_US';
  SimpleOpusDecoder? _decoder;
  BleAudioCodec? _activeCodec;

  /// Latest transcript — UI subscribes to this.
  final ValueNotifier<String> liveTranscript = ValueNotifier<String>('');

  /// True between start (after auth + first push) and stop.
  bool get isActive => _isActive;

  // -------- Wiring callbacks (driven from ProxyProvider in main.dart) --------

  void onPendantStateChanged(PendantState state, BleAudioCodec? codec) {
    final shouldRun = state == PendantState.live && codec != null;
    if (shouldRun && !_isActive) {
      _activeCodec = codec;
      unawaited(_start());
    } else if (!shouldRun && _isActive) {
      _stop();
    }
  }

  void onLocaleChanged(Locale appLocale) {
    final next = _localeIdFor(appLocale);
    if (next == _currentLocaleId) return;
    _currentLocaleId = next;
    if (_isActive) {
      // Restart so SFSpeechRecognizer picks up the new locale.
      _stop();
      unawaited(_start());
    }
  }

  // -------- Start / Stop --------

  Future<void> _start() async {
    await _ensureOpusInitialized();
    final codec = _activeCodec;
    if (codec == null) return;
    final sampleRate = sampleRateForCodec(codec);
    _decoder = _decoderFor(codec, sampleRate);
    final ok = await _bridge.start(localeId: _currentLocaleId ?? 'en_US', sampleRate: sampleRate);
    if (!ok) {
      _decoder = null;
      return;
    }
    _isActive = true;
    _audioSub = _pendant.audioBytes.listen(_onAudioChunk);
    notifyListeners();
  }

  void _stop() {
    _audioSub?.cancel();
    _audioSub = null;
    unawaited(_bridge.stop());
    _decoder?.destroy();
    _decoder = null;
    _isActive = false;
    liveTranscript.value = '';
    notifyListeners();
  }

  // -------- Decode + push --------

  void _onAudioChunk(List<int> bytes) {
    if (!_isActive) return;
    final decoder = _decoder;
    final codec = _activeCodec;
    if (decoder == null || codec == null) return;
    try {
      final Int16List pcm;
      if (codec == BleAudioCodec.pcm8 || codec == BleAudioCodec.pcm16) {
        // Already PCM — pass through with little-endian byte order.
        pcm = Int16List.view(Uint8List.fromList(bytes).buffer);
      } else {
        // Opus — decode to PCM samples.
        pcm = decoder.decode(input: Uint8List.fromList(bytes));
      }
      if (pcm.isEmpty) return;
      // Convert Int16List to Uint8List (little-endian) for the channel.
      final byteData = ByteData(pcm.length * 2);
      for (var i = 0; i < pcm.length; i++) {
        byteData.setInt16(i * 2, pcm[i], Endian.little);
      }
      unawaited(_bridge.appendPcm(byteData.buffer.asUint8List()));
    } catch (e) {
      debugPrint('[PendantSttProvider] decode/push error: $e');
    }
  }

  void _onResult(PendantSttResult result) {
    if (!_isActive) return;
    liveTranscript.value = result.text;
  }

  // -------- Opus init --------

  Future<void> _ensureOpusInitialized() async {
    if (_opusInitialized) return;
    if (!_isSupportedPlatform) return;
    try {
      initOpus(await opus_flutter.load());
      _opusInitialized = true;
    } catch (e) {
      debugPrint('[PendantSttProvider] opus init failed: $e');
    }
  }

  SimpleOpusDecoder _decoderFor(BleAudioCodec codec, int sampleRate) {
    return SimpleOpusDecoder(sampleRate: sampleRate, channels: 1);
  }

  static String _localeIdFor(Locale l) {
    if (l.countryCode != null && l.countryCode!.isNotEmpty) {
      return '${l.languageCode}_${l.countryCode}';
    }
    switch (l.languageCode) {
      case 'en':
        return 'en_US';
      case 'pt':
        return 'pt_BR';
      default:
        return l.languageCode;
    }
  }

  bool get _isSupportedPlatform => defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void dispose() {
    _audioSub?.cancel();
    _resultsSub?.cancel();
    _decoder?.destroy();
    _bridge.dispose();
    liveTranscript.dispose();
    super.dispose();
  }
}
