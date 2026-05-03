import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nooto_v2/audio/codec.dart';
import 'package:nooto_v2/services/ble/socket_streamer.dart';

/// Minimal [WebSocket] fake driven by tests. Captures sends and exposes
/// `closeWith()` to simulate server-driven close codes.
class _FakeWebSocket implements WebSocket {
  _FakeWebSocket(this._headers);

  final Map<String, dynamic>? _headers;
  Map<String, dynamic>? get headers => _headers;

  final List<List<int>> sent = [];
  final StreamController<dynamic> _ctl = StreamController<dynamic>();
  int? _closeCode;
  String? _closeReason;
  bool _closed = false;

  @override
  void add(dynamic data) {
    if (_closed) throw StateError('socket closed');
    sent.add(List<int>.from(data as List<int>));
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed) return;
    _closed = true;
    _closeCode = code;
    _closeReason = reason;
    await _ctl.close();
  }

  void closeWith(int code, [String? reason]) {
    if (_closed) return;
    _closed = true;
    _closeCode = code;
    _closeReason = reason;
    _ctl.close();
  }

  @override
  int? get closeCode => _closeCode;
  @override
  String? get closeReason => _closeReason;

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _ctl.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SocketBuilder {
  _SocketBuilder();
  final List<Uri> uris = [];
  final List<Map<String, dynamic>?> headers = [];
  final List<_FakeWebSocket> sockets = [];

  Future<WebSocket> Function(Uri, {Map<String, dynamic>? headers}) get fn =>
      (uri, {Map<String, dynamic>? headers}) async {
        uris.add(uri);
        this.headers.add(headers);
        final ws = _FakeWebSocket(headers);
        sockets.add(ws);
        return ws;
      };
}

void main() {
  group('SocketStreamer.connect', () {
    test('attaches Bearer token on the upgrade headers', () async {
      final builder = _SocketBuilder();
      final s = SocketStreamer(
        socketBuilder: builder.fn,
        getIdToken: ({bool forceRefresh = false}) async => 'tok-1',
        baseUrl: 'https://example.test/',
        uid: 'user-1',
      );

      await s.connect(codec: BleAudioCodec.opus);
      expect(builder.sockets, hasLength(1));
      // dart:io's WebSocket.connect lowercases header keys per HTTP spec.
      expect(builder.headers.first?[HttpHeaders.authorizationHeader], 'Bearer tok-1');
      expect(builder.uris.first.scheme, 'wss');
      expect(builder.uris.first.queryParameters['uid'], 'user-1');
      expect(builder.uris.first.queryParameters['codec'], 'BleAudioCodec.opus');
      await s.close();
    });

    test('omits Authorization when token is null', () async {
      final builder = _SocketBuilder();
      final s = SocketStreamer(
        socketBuilder: builder.fn,
        getIdToken: ({bool forceRefresh = false}) async => null,
        baseUrl: 'https://example.test/',
      );
      await s.connect(codec: BleAudioCodec.opus);
      expect(builder.headers.first?[HttpHeaders.authorizationHeader], isNull);
      await s.close();
    });
  });

  group('SocketStreamer.send', () {
    test('forwards bytes when open', () async {
      final builder = _SocketBuilder();
      final s = SocketStreamer(
        socketBuilder: builder.fn,
        getIdToken: ({bool forceRefresh = false}) async => 'tok',
        baseUrl: 'https://example.test/',
      );
      await s.connect(codec: BleAudioCodec.opus);

      s.send([1, 2, 3]);
      s.send([4, 5]);
      expect(builder.sockets.first.sent, [
        [1, 2, 3],
        [4, 5],
      ]);
      await s.close();
    });

    test('drops silently while not connected', () async {
      final builder = _SocketBuilder();
      final s = SocketStreamer(
        socketBuilder: builder.fn,
        getIdToken: ({bool forceRefresh = false}) async => 'tok',
        baseUrl: 'https://example.test/',
      );

      // No connect — send before any open.
      expect(() => s.send([1, 2, 3]), returnsNormally);
      expect(builder.sockets, isEmpty);
    });
  });

  group('SocketStreamer close-code policy', () {
    test('1000 (normal) reconnects immediately', () async {
      final builder = _SocketBuilder();
      final s = SocketStreamer(
        socketBuilder: builder.fn,
        getIdToken: ({bool forceRefresh = false}) async => 'tok',
        baseUrl: 'https://example.test/',
      );
      await s.connect(codec: BleAudioCodec.opus);
      builder.sockets.first.closeWith(WebSocketStatus.normalClosure);

      // Wait for the zero-delay reconnect timer.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(builder.sockets, hasLength(2));
      await s.close();
    });

    test('1006 (abnormal) backoff schedule reconnects', () async {
      final builder = _SocketBuilder();
      final s = SocketStreamer(
        socketBuilder: builder.fn,
        getIdToken: ({bool forceRefresh = false}) async => 'tok',
        baseUrl: 'https://example.test/',
        abnormalBackoff: const [Duration(milliseconds: 5)],
      );
      await s.connect(codec: BleAudioCodec.opus);
      builder.sockets.first.closeWith(WebSocketStatus.abnormalClosure);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(builder.sockets.length, greaterThanOrEqualTo(2));
      await s.close();
    });

    test('1008 forces token refresh and reconnects, terminal after 3 fails', () async {
      final builder = _SocketBuilder();
      final refreshes = <bool>[];
      final s = SocketStreamer(
        socketBuilder: builder.fn,
        getIdToken: ({bool forceRefresh = false}) async {
          refreshes.add(forceRefresh);
          return forceRefresh ? 'tok-refreshed' : 'tok';
        },
        baseUrl: 'https://example.test/',
      );
      final terminal = Completer<SocketTerminal>();
      s.events.listen((e) {
        if (e is SocketTerminal && !terminal.isCompleted) {
          terminal.complete(e);
        }
      });

      await s.connect(codec: BleAudioCodec.opus);
      // Initial connect uses non-force token.
      expect(refreshes.first, false);

      // Drive 4 closures (the 4th overruns the 3-retry limit).
      for (var i = 0; i < 4; i++) {
        builder.sockets.last.closeWith(WebSocketStatus.policyViolation);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      final t = await terminal.future.timeout(const Duration(seconds: 1));
      expect(t.code, WebSocketStatus.policyViolation);
      // Each 1008 close kicks a forceRefresh reconnect attempt.
      expect(refreshes.where((r) => r).length, greaterThanOrEqualTo(3));
      await s.close();
    });

    test('4xxx custom auth code follows the 1008 path', () async {
      final builder = _SocketBuilder();
      final refreshes = <bool>[];
      final s = SocketStreamer(
        socketBuilder: builder.fn,
        getIdToken: ({bool forceRefresh = false}) async {
          refreshes.add(forceRefresh);
          return 'tok';
        },
        baseUrl: 'https://example.test/',
      );
      await s.connect(codec: BleAudioCodec.opus);
      builder.sockets.first.closeWith(4001, 'auth expired');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // The reconnect attempt forced a refresh.
      expect(refreshes.last, true);
      await s.close();
    });

    test('1009 keeps the connection (immediate reconnect)', () async {
      final builder = _SocketBuilder();
      final s = SocketStreamer(
        socketBuilder: builder.fn,
        getIdToken: ({bool forceRefresh = false}) async => 'tok',
        baseUrl: 'https://example.test/',
      );
      await s.connect(codec: BleAudioCodec.opus);
      builder.sockets.first.closeWith(WebSocketStatus.messageTooBig);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(builder.sockets, hasLength(2));
      await s.close();
    });

    test('1011 backoff schedule, terminal after 5 fails', () async {
      final builder = _SocketBuilder();
      final s = SocketStreamer(
        socketBuilder: builder.fn,
        getIdToken: ({bool forceRefresh = false}) async => 'tok',
        baseUrl: 'https://example.test/',
        serverErrorBackoff: const [
          Duration(milliseconds: 5),
          Duration(milliseconds: 5),
          Duration(milliseconds: 5),
          Duration(milliseconds: 5),
          Duration(milliseconds: 5),
        ],
      );
      final terminal = Completer<SocketTerminal>();
      s.events.listen((e) {
        if (e is SocketTerminal && !terminal.isCompleted) {
          terminal.complete(e);
        }
      });

      await s.connect(codec: BleAudioCodec.opus);
      // 6 closes: 5 retries, 6th trips the terminal.
      for (var i = 0; i < 6; i++) {
        builder.sockets.last.closeWith(WebSocketStatus.internalServerError);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      final t = await terminal.future.timeout(const Duration(seconds: 2));
      expect(t.code, WebSocketStatus.internalServerError);
      await s.close();
    });

    test('1013 honors retry-after hint in close reason', () async {
      final builder = _SocketBuilder();
      final s = SocketStreamer(
        socketBuilder: builder.fn,
        getIdToken: ({bool forceRefresh = false}) async => 'tok',
        baseUrl: 'https://example.test/',
      );
      await s.connect(codec: BleAudioCodec.opus);
      // 1013 with retry-after:1 means try again in 1 second. We just
      // assert no immediate reconnect within the first 100ms.
      builder.sockets.first.closeWith(1013, 'retry-after:1');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(builder.sockets, hasLength(1));
      await s.close();
    });
  });
}
