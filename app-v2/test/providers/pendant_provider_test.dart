import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:nooto_v2/audio/codec.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/services/ble/omi_pendant.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/services/ble/socket_streamer.dart';

class _FakeBox<T> implements Box<T> {
  final Map<dynamic, dynamic> _store = {};

  @override
  Future<void> put(dynamic key, T value) async {
    _store[key] = value;
  }

  @override
  T? get(dynamic key, {T? defaultValue}) => (_store[key] as T?) ?? defaultValue;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBleAdapter implements BleAdapter {
  _FakeBleAdapter({this.scanResultsToEmit = const [], this.servicesToReturn = const [], this.codecBytes = const [20]});

  List<List<BleScanResult>> scanResultsToEmit;
  List<BleService> servicesToReturn;
  List<int> codecBytes;
  String? connectedDeviceId;

  final Map<String, StreamController<bool>> _connStateCtls = {};
  final Map<String, StreamController<List<int>>> _charCtls = {};

  @override
  Future<void> startScan({required List<String> serviceUuids, required Duration timeout}) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Stream<List<BleScanResult>> get scanResults async* {
    for (final batch in scanResultsToEmit) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      yield batch;
    }
  }

  @override
  Future<void> connectDevice(String deviceId) async {
    connectedDeviceId = deviceId;
    final ctl = _connStateCtls.putIfAbsent(deviceId, () => StreamController<bool>.broadcast());
    scheduleMicrotask(() {
      if (!ctl.isClosed) ctl.add(true);
    });
  }

  @override
  Future<void> disconnectDevice(String deviceId) async {
    final ctl = _connStateCtls[deviceId];
    if (ctl != null && !ctl.isClosed) ctl.add(false);
  }

  @override
  Stream<bool> deviceConnectionState(String deviceId) {
    return _connStateCtls.putIfAbsent(deviceId, () => StreamController<bool>.broadcast()).stream;
  }

  void emitDisconnect(String deviceId) {
    final ctl = _connStateCtls[deviceId];
    if (ctl != null && !ctl.isClosed) ctl.add(false);
  }

  void emitAudio(BleCharacteristicRef ref, List<int> bytes) {
    final ctl = _charCtls['$ref'];
    if (ctl != null && !ctl.isClosed) ctl.add(bytes);
  }

  @override
  Future<List<BleService>> discoverServices(String deviceId) async => servicesToReturn;

  @override
  Future<List<int>> readCharacteristic(String deviceId, BleCharacteristicRef ref) async {
    if (ref.uuid.toLowerCase() == OmiPendant.audioCodecCharacteristicUuid) {
      return codecBytes;
    }
    return const [];
  }

  @override
  Future<void> setNotifyValue(String deviceId, BleCharacteristicRef ref, bool notify) async {
    _charCtls.putIfAbsent('$ref', () => StreamController<List<int>>.broadcast());
  }

  @override
  Stream<List<int>> characteristicStream(String deviceId, BleCharacteristicRef ref) {
    return _charCtls.putIfAbsent('$ref', () => StreamController<List<int>>.broadcast()).stream;
  }
}

class _FakeWebSocket implements WebSocket {
  final List<List<int>> sent = [];
  final StreamController<dynamic> _ctl = StreamController<dynamic>();
  int? _closeCode;
  String? _closeReason;
  bool _closed = false;

  @override
  void add(dynamic data) {
    if (_closed) throw StateError('closed');
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
  }) => _ctl.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BleService _omiAudioService() => BleService(
  uuid: OmiPendant.omiServiceUuid,
  characteristics: [
    BleCharacteristicRef(serviceUuid: OmiPendant.omiServiceUuid, uuid: OmiPendant.audioDataCharacteristicUuid),
    BleCharacteristicRef(serviceUuid: OmiPendant.omiServiceUuid, uuid: OmiPendant.audioCodecCharacteristicUuid),
  ],
);

BleScanResult _omiScanResult({String id = 'AA'}) =>
    BleScanResult(deviceId: id, deviceName: 'Omi', serviceUuids: [OmiPendant.omiServiceUuid]);

class _Harness {
  _Harness({Box<dynamic>? box, _FakeBleAdapter? adapter})
    : box = box ?? _FakeBox<dynamic>(),
      adapter = adapter ?? _FakeBleAdapter() {
    pendant = OmiPendant(
      bleAdapter: this.adapter,
      persistenceBox: this.box,
      requestBlePermissions: () async => true,
      requestMicPermission: () async => true,
      backoffSchedule: const [Duration(milliseconds: 5)],
      giveUpAfter: const Duration(milliseconds: 50),
    );
    socketBuilds = [];
    streamer = SocketStreamer(
      socketBuilder: (uri, {Map<String, dynamic>? headers}) async {
        final ws = _FakeWebSocket();
        socketBuilds.add(ws);
        return ws;
      },
      getIdToken: ({bool forceRefresh = false}) async => 'tok',
      baseUrl: 'https://example.test/',
    );
    provider = PendantProvider(pendant: pendant, socket: streamer);
  }

  final Box<dynamic> box;
  final _FakeBleAdapter adapter;
  late final OmiPendant pendant;
  late final List<_FakeWebSocket> socketBuilds;
  late final SocketStreamer streamer;
  late final PendantProvider provider;
}

void main() {
  group('PendantProvider state machine', () {
    test('startPair → live wires socket open with negotiated codec', () async {
      final h = _Harness(
        adapter: _FakeBleAdapter(
          scanResultsToEmit: [
            [_omiScanResult()],
          ],
          servicesToReturn: [_omiAudioService()],
          codecBytes: const [20],
        ),
      );

      await h.provider.startPair();
      // Allow the unawaited socket.connect to settle.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.provider.info.state, PendantState.live);
      expect(h.provider.info.codec, BleAudioCodec.opus);
      expect(h.socketBuilds, hasLength(1));
      await h.streamer.close();
    });

    test('forwards audio bytes from pendant stream to socket', () async {
      final h = _Harness(
        adapter: _FakeBleAdapter(
          scanResultsToEmit: [
            [_omiScanResult()],
          ],
          servicesToReturn: [_omiAudioService()],
          codecBytes: const [20],
        ),
      );
      await h.provider.startPair();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.provider.info.state, PendantState.live);

      final ref = BleCharacteristicRef(
        serviceUuid: OmiPendant.omiServiceUuid,
        uuid: OmiPendant.audioDataCharacteristicUuid,
      );
      h.adapter.emitAudio(ref, [1, 0, 0, 10, 20, 30]);
      h.adapter.emitAudio(ref, [2, 0, 1, 40, 50]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(h.socketBuilds.first.sent, [
        [10, 20, 30],
        [40, 50],
      ]);
      await h.streamer.close();
    });

    test('drop counter resets on transition to live', () async {
      final h = _Harness(
        adapter: _FakeBleAdapter(
          scanResultsToEmit: [
            [_omiScanResult()],
          ],
          servicesToReturn: [_omiAudioService()],
          codecBytes: const [20],
        ),
      );
      await h.provider.startPair();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      h.pendant.reportInterruption(began: true);
      expect(h.provider.info.state, PendantState.interrupted);

      final ref = BleCharacteristicRef(
        serviceUuid: OmiPendant.omiServiceUuid,
        uuid: OmiPendant.audioDataCharacteristicUuid,
      );
      h.adapter.emitAudio(ref, [1, 0, 0, 1]);
      h.adapter.emitAudio(ref, [2, 0, 1, 2]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(h.provider.info.droppedPacketsLastInterrupt, 2);

      h.pendant.reportInterruption(began: false);
      expect(h.provider.info.state, PendantState.live);
      expect(h.provider.info.droppedPacketsLastInterrupt, 0);
      await h.streamer.close();
    });

    test('pauseFor disconnects then reconnects', () async {
      final h = _Harness(
        adapter: _FakeBleAdapter(
          scanResultsToEmit: [
            [_omiScanResult()],
          ],
          servicesToReturn: [_omiAudioService()],
          codecBytes: const [20],
        ),
      );
      await h.provider.startPair();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.provider.info.state, PendantState.live);

      // Schedule pauseFor; while paused state should leave `live`.
      final pauseFuture = h.provider.pauseFor(const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(h.provider.info.state, isNot(PendantState.live));

      await pauseFuture;
      // After pauseFor, we attempt to reconnect — the state machine fires
      // through connecting → live again.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.provider.info.state, PendantState.live);
      await h.streamer.close();
    });
  });

  group('PendantProvider Hive bootstrap', () {
    test('bootstrap reads stored deviceId and auto-connects', () async {
      final box = _FakeBox<dynamic>();
      await box.put('lastDeviceId', 'PAIRED-XYZ');
      await box.put('lastDeviceName', 'Omi');

      final h = _Harness(
        box: box,
        adapter: _FakeBleAdapter(
          scanResultsToEmit: const [],
          servicesToReturn: [_omiAudioService()],
          codecBytes: const [20],
        ),
      );

      await h.provider.bootstrap();
      // Allow the live transition + socket open to settle.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.adapter.connectedDeviceId, 'PAIRED-XYZ');
      expect(h.provider.info.state, PendantState.live);
      await h.streamer.close();
    });

    test('startPair persists last paired deviceId', () async {
      final box = _FakeBox<dynamic>();
      final h = _Harness(
        box: box,
        adapter: _FakeBleAdapter(
          scanResultsToEmit: [
            [_omiScanResult(id: 'NEW-DEVICE')],
          ],
          servicesToReturn: [_omiAudioService()],
          codecBytes: const [20],
        ),
      );

      await h.provider.startPair();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(box.get('lastDeviceId'), 'NEW-DEVICE');
      await h.streamer.close();
    });
  });
}
