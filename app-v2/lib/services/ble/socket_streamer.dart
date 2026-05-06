import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:nooto_v2/audio/codec.dart';
import 'package:nooto_v2/services/auth_service.dart';

/// Events emitted by [SocketStreamer] for the provider to react to.
sealed class SocketEvent {
  const SocketEvent();
}

class SocketOpened extends SocketEvent {
  const SocketOpened();
}

class SocketClosed extends SocketEvent {
  const SocketClosed({required this.code, this.reason});
  final int code;
  final String? reason;
}

/// Final close — caller should treat as terminal (e.g. flip pendant to
/// `offline`). Emitted after the policy table exhausts its retries for
/// 1008/1011/4xxx codes.
class SocketTerminal extends SocketEvent {
  const SocketTerminal({required this.code, this.reason});
  final int code;
  final String? reason;
}

/// Transcript segments pushed back from the backend (Deepgram running on
/// pendant audio). Backend's `v4/listen` socket emits JSON arrays of
/// segments; we concatenate their `text` field into one delta per event
/// so UI consumers can build a rolling transcript without re-implementing
/// the JSON schema. Per 2026-05-05 dogfood, this is the path that makes
/// "live transcription" reflect what the PENDANT heard, not the phone mic.
class SocketTranscript extends SocketEvent {
  const SocketTranscript({required this.text, required this.segmentCount});
  final String text;
  final int segmentCount;
}

/// Backend WebSocket streamer for the Omi pendant audio path.
///
/// Wraps `wss://{baseUrl}/v4/listen` with the full backend param set (copied
/// from legacy `app/lib/services/sockets/transcription_service.dart`),
/// attaches the Firebase ID token as `Authorization: Bearer …` on the
/// upgrade, and reconnects per the close-code policy table in the design
/// doc:
///
/// | Code | Behavior | Backoff | Terminal? |
/// |---|---|---|---|
/// | 1000 | reconnect immediately | 0s | no |
/// | 1006 | reconnect with backoff | 1s/2s/5s/10s | no |
/// | 1008 | force-refresh token, reconnect | 0s | after 3 fails |
/// | 1009 | drop offending packet, keep connection | n/a | no |
/// | 1011 | reconnect with backoff | 5s/15s/30s | after 5 fails |
/// | 1013 | honor `retry-after:<sec>` reason or 30s | per server | no |
/// | 4xxx | force-refresh token, reconnect | 0s | after 3 fails |
///
/// Constructor seams (`socketBuilder`, `getIdToken`, `baseUrl`) mirror
/// `services/api_client.dart:54-70` so tests can drive the close-code
/// matrix without spinning up Firebase or a real WebSocket.
class SocketStreamer {
  SocketStreamer({
    Future<WebSocket> Function(Uri, {Map<String, dynamic>? headers})? socketBuilder,
    Future<String?> Function({bool forceRefresh})? getIdToken,
    String? baseUrl,
    String? uid,
    List<Duration>? abnormalBackoff,
    List<Duration>? serverErrorBackoff,
  }) : _builder = socketBuilder ?? _defaultSocketBuilder,
       _getIdToken = getIdToken ?? AuthService.instance.getIdToken,
       _baseUrl = baseUrl ?? _defaultBaseUrl,
       _uid = uid,
       _abnormalBackoff = abnormalBackoff ?? _defaultAbnormalBackoff,
       _serverErrorBackoff = serverErrorBackoff ?? _defaultServerErrorBackoff;

  // Same default as ApiClient — keep in sync until v2 cuts over to prod.
  static const String _defaultBaseUrl = 'https://nooto-dev.togodynamics.com/';
  static const String _path = 'v4/listen';

  static const List<Duration> _defaultAbnormalBackoff = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];
  static const List<Duration> _defaultServerErrorBackoff = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];
  static const Duration _busyRetry = Duration(seconds: 30);
  static const int _authRetryLimit = 3;
  static const int _serverRetryLimit = 5;

  /// `WebSocketStatus.tryAgainLater` (1013) isn't exposed by Dart's
  /// `WebSocketStatus` constants, so we use the literal close code from
  /// RFC 6455 (well, the IANA registry — RFC 7232 reserved 1013).
  static const int _wsTryAgainLater = 1013;

  final Future<WebSocket> Function(Uri, {Map<String, dynamic>? headers}) _builder;
  final Future<String?> Function({bool forceRefresh}) _getIdToken;
  final String _baseUrl;
  final String? _uid;
  final List<Duration> _abnormalBackoff;
  final List<Duration> _serverErrorBackoff;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  BleAudioCodec? _codec;
  bool _open = false;
  bool _disposed = false;

  // Retry state.
  int _authRetries = 0;
  int _serverRetries = 0;
  int _abnormalIndex = 0;
  Timer? _reconnectTimer;

  final StreamController<SocketEvent> _events = StreamController<SocketEvent>.broadcast();
  Stream<SocketEvent> get events => _events.stream;

  bool get isOpen => _open;

  /// Establish the connection. Subsequent [send] calls flow data through.
  Future<void> connect({required BleAudioCodec codec}) async {
    _codec = codec;
    await _establish();
  }

  /// Forward a raw audio packet. No-op while not open (matches the
  /// design-doc online-only contract).
  void send(List<int> bytes) {
    if (!_open || _socket == null) return;
    try {
      _socket!.add(bytes);
    } on StateError {
      // Socket closed mid-send. Mark closed; close handler reschedules.
      _open = false;
    } catch (e) {
      debugPrint('[SocketStreamer] send error: $e');
    }
  }

  /// Close cleanly. Halts the reconnect loop.
  Future<void> close() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _open = false;
    await _socketSub?.cancel();
    _socketSub = null;
    final s = _socket;
    _socket = null;
    if (s != null) {
      try {
        await s.close(WebSocketStatus.normalClosure);
      } catch (_) {}
    }
  }

  /// Permanent dispose. After this call the streamer no longer reconnects.
  Future<void> dispose() async {
    await close();
    await _events.close();
  }

  Future<void> _establish({bool forceRefreshToken = false}) async {
    if (_disposed) return;
    final codec = _codec;
    if (codec == null) return;

    final token = await _getIdToken(forceRefresh: forceRefreshToken);
    final uri = _buildUri(codec);
    final headers = <String, dynamic>{
      if (token != null && token.isNotEmpty) HttpHeaders.authorizationHeader: 'Bearer $token',
    };

    try {
      final ws = await _builder(uri, headers: headers);
      _socket = ws;
      _open = true;
      _abnormalIndex = 0;
      _events.add(const SocketOpened());
      _socketSub = ws.listen(
        (raw) {
          // Backend pushes JSON over the same socket. Two shapes we care
          // about (mirrors legacy `transcription_service.dart:204-242`):
          //   1. List<{id, text, ...}> — transcript segments (the case we
          //      surface as SocketTranscript for UI).
          //   2. Map with `type` field — message events (currently ignored
          //      in v2; no consumers).
          // Anything else is silently dropped.
          if (raw is! String) return;
          dynamic decoded;
          try {
            decoded = jsonDecode(raw);
          } on FormatException {
            return;
          }
          if (decoded is List && decoded.isNotEmpty) {
            final buf = StringBuffer();
            var count = 0;
            for (final seg in decoded) {
              if (seg is Map && seg['text'] is String) {
                final text = (seg['text'] as String).trim();
                if (text.isEmpty) continue;
                if (buf.isNotEmpty) buf.write(' ');
                buf.write(text);
                count++;
              }
            }
            if (count > 0) {
              _events.add(SocketTranscript(text: buf.toString(), segmentCount: count));
            }
          }
        },
        onDone: () => _onClosed(ws.closeCode ?? WebSocketStatus.abnormalClosure, ws.closeReason),
        onError: (e) {
          debugPrint('[SocketStreamer] socket error: $e');
          _onClosed(WebSocketStatus.abnormalClosure, '$e');
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('[SocketStreamer] connect error: $e');
      _onClosed(WebSocketStatus.abnormalClosure, '$e');
    }
  }

  void _onClosed(int code, String? reason) {
    _open = false;
    _socketSub?.cancel();
    _socketSub = null;
    _socket = null;
    _events.add(SocketClosed(code: code, reason: reason));

    if (_disposed) return;

    // Apply close-code policy.
    if (code == WebSocketStatus.normalClosure /* 1000 */ ) {
      _scheduleReconnect(Duration.zero);
      return;
    }
    if (code == WebSocketStatus.abnormalClosure /* 1006 */ ) {
      final delay = _abnormalBackoff[_abnormalIndex.clamp(0, _abnormalBackoff.length - 1)];
      _abnormalIndex = (_abnormalIndex + 1).clamp(0, _abnormalBackoff.length - 1);
      _scheduleReconnect(delay);
      return;
    }
    if (code == WebSocketStatus.policyViolation /* 1008 */ || (code >= 4001 && code <= 4999)) {
      _authRetries += 1;
      if (_authRetries > _authRetryLimit) {
        _authRetries = 0;
        _events.add(SocketTerminal(code: code, reason: reason));
        return;
      }
      _scheduleReconnect(Duration.zero, forceRefresh: true);
      return;
    }
    if (code == WebSocketStatus.messageTooBig /* 1009 */ ) {
      // Per the policy table: drop the offending packet and keep going.
      // The backend already closed our socket — reconnect immediately.
      _scheduleReconnect(Duration.zero);
      return;
    }
    if (code == WebSocketStatus.internalServerError /* 1011 */ ) {
      _serverRetries += 1;
      if (_serverRetries > _serverRetryLimit) {
        _serverRetries = 0;
        _events.add(SocketTerminal(code: code, reason: reason));
        return;
      }
      final idx = (_serverRetries - 1).clamp(0, _serverErrorBackoff.length - 1);
      _scheduleReconnect(_serverErrorBackoff[idx]);
      return;
    }
    if (code == _wsTryAgainLater /* 1013 — not in WebSocketStatus */ ) {
      _scheduleReconnect(_parseRetryAfter(reason));
      return;
    }

    // Unknown — treat as abnormal.
    final delay = _abnormalBackoff[_abnormalIndex.clamp(0, _abnormalBackoff.length - 1)];
    _abnormalIndex = (_abnormalIndex + 1).clamp(0, _abnormalBackoff.length - 1);
    _scheduleReconnect(delay);
  }

  void _scheduleReconnect(Duration delay, {bool forceRefresh = false}) {
    _reconnectTimer?.cancel();
    // Even for `Duration.zero` we route through Timer so we never
    // re-enter `_establish` synchronously from inside `_onClosed`.
    _reconnectTimer = Timer(delay, () => _establish(forceRefreshToken: forceRefresh));
  }

  Uri _buildUri(BleAudioCodec codec) {
    final baseHttp = _baseUrl.endsWith('/') ? _baseUrl : '$_baseUrl/';
    final base = baseHttp.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://');
    final uid = _uid;
    final params = <String, String>{
      'language': 'en',
      'sample_rate': sampleRateForCodec(codec).toString(),
      'codec': _codecParam(codec),
      if (uid != null && uid.isNotEmpty) 'uid': uid,
      'include_speech_profile': 'false',
      'stt_service': 'soniox',
      'conversation_timeout': '120',
      'speaker_auto_assign': 'enabled',
    };
    final qs = params.entries
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return Uri.parse('$base$_path?$qs');
  }

  static String _codecParam(BleAudioCodec codec) {
    // Mirror the legacy `BleAudioCodec.toString()` enum format
    // (`BleAudioCodec.opus`).
    switch (codec) {
      case BleAudioCodec.pcm8:
        return 'BleAudioCodec.pcm8';
      case BleAudioCodec.pcm16:
        return 'BleAudioCodec.pcm16';
      case BleAudioCodec.opus:
        return 'BleAudioCodec.opus';
      case BleAudioCodec.opusFS320:
        return 'BleAudioCodec.opusFS320';
      case BleAudioCodec.unknown:
        return 'BleAudioCodec.unknown';
    }
  }

  static Duration _parseRetryAfter(String? reason) {
    if (reason == null) return _busyRetry;
    final m = RegExp(r'retry-after:(\d+)').firstMatch(reason.toLowerCase());
    if (m == null) return _busyRetry;
    final secs = int.tryParse(m.group(1) ?? '');
    if (secs == null || secs <= 0) return _busyRetry;
    return Duration(seconds: secs);
  }
}

Future<WebSocket> _defaultSocketBuilder(Uri uri, {Map<String, dynamic>? headers}) {
  return WebSocket.connect(uri.toString(), headers: headers);
}
