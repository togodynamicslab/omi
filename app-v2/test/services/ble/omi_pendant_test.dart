import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:nooto_v2/audio/codec.dart';
import 'package:nooto_v2/services/ble/omi_pendant.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';

/// Fake Hive box that stores values in memory. Avoids file IO.
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
  _FakeBleAdapter({required this.scanResultsToEmit, required this.servicesToReturn, required this.codecBytes});

  final List<List<BleScanResult>> scanResultsToEmit;
  final List<BleService> servicesToReturn;
  List<int> codecBytes;

  final Map<String, StreamController<bool>> _connStateCtls = {};
  final Map<String, StreamController<List<int>>> _charCtls = {};

  bool startScanCalled = false;
  bool stopScanCalled = false;
  bool connectCalled = false;
  String? connectedDeviceId;
  bool throwOnConnect = false;
  Map<String, List<int>> initialCharValues = {};

  @override
  Future<void> startScan({required List<String> serviceUuids, required Duration timeout}) async {
    startScanCalled = true;
  }

  @override
  Stream<List<BleScanResult>> get scanResults => _scanResultsStream();

  /// Returns a fresh single-subscription stream each call so the
  /// `firstWhere` consumer gets the buffered batches even though attach
  /// happens after `startScan` in the production code path.
  Stream<List<BleScanResult>> _scanResultsStream() async* {
    for (final batch in scanResultsToEmit) {
      // Yield after a microtask so the consumer's await-loop has a chance
      // to attach. This mirrors flutter_blue_plus's behavior of streaming
      // discoveries in over time.
      await Future<void>.delayed(const Duration(milliseconds: 1));
      yield batch;
    }
  }

  @override
  Future<void> stopScan() async {
    stopScanCalled = true;
  }

  @override
  Future<void> connectDevice(String deviceId) async {
    connectCalled = true;
    if (throwOnConnect) throw Exception('connect failed');
    connectedDeviceId = deviceId;
    final ctl = _connStateCtls.putIfAbsent(deviceId, () => StreamController<bool>.broadcast());
    scheduleMicrotask(() {
      if (!ctl.isClosed) ctl.add(true);
    });
  }

  @override
  Future<void> disconnectDevice(String deviceId) async {
    final ctl = _connStateCtls[deviceId];
    if (ctl != null && !ctl.isClosed) {
      ctl.add(false);
    }
  }

  @override
  Stream<bool> deviceConnectionState(String deviceId) {
    final ctl = _connStateCtls.putIfAbsent(deviceId, () => StreamController<bool>.broadcast());
    return ctl.stream;
  }

  void emitDisconnect(String deviceId) {
    final ctl = _connStateCtls[deviceId];
    if (ctl != null && !ctl.isClosed) ctl.add(false);
  }

  void emitAudio(BleCharacteristicRef ref, List<int> bytes) {
    final key = '$ref';
    final ctl = _charCtls[key];
    if (ctl != null && !ctl.isClosed) ctl.add(bytes);
  }

  @override
  Future<List<BleService>> discoverServices(String deviceId) async {
    return servicesToReturn;
  }

  @override
  Future<List<int>> readCharacteristic(String deviceId, BleCharacteristicRef ref) async {
    if (ref.uuid.toLowerCase() == OmiPendant.audioCodecCharacteristicUuid) {
      return codecBytes;
    }
    return initialCharValues['$ref'] ?? const [];
  }

  @override
  Future<void> setNotifyValue(String deviceId, BleCharacteristicRef ref, bool notify) async {
    _charCtls.putIfAbsent('$ref', () => StreamController<List<int>>.broadcast());
  }

  @override
  Stream<List<int>> characteristicStream(String deviceId, BleCharacteristicRef ref) {
    final ctl = _charCtls.putIfAbsent('$ref', () => StreamController<List<int>>.broadcast());
    return ctl.stream;
  }
}

BleService _omiAudioService() => BleService(
  uuid: OmiPendant.omiServiceUuid,
  characteristics: [
    BleCharacteristicRef(serviceUuid: OmiPendant.omiServiceUuid, uuid: OmiPendant.audioDataCharacteristicUuid),
    BleCharacteristicRef(serviceUuid: OmiPendant.omiServiceUuid, uuid: OmiPendant.audioCodecCharacteristicUuid),
  ],
);

BleService _batteryService() => BleService(
  uuid: OmiPendant.batteryServiceUuid,
  characteristics: [
    BleCharacteristicRef(serviceUuid: OmiPendant.batteryServiceUuid, uuid: OmiPendant.batteryCharacteristicUuid),
  ],
);

BleScanResult _omiScanResult({String id = 'AA:BB:CC'}) =>
    BleScanResult(deviceId: id, deviceName: 'Omi Pendant', serviceUuids: [OmiPendant.omiServiceUuid]);

void main() {
  group('OmiPendant.startPair', () {
    test('happy path → live with negotiated codec', () async {
      final adapter = _FakeBleAdapter(
        scanResultsToEmit: [
          [_omiScanResult()],
        ],
        servicesToReturn: [_omiAudioService(), _batteryService()],
        codecBytes: const [20], // opus
      );
      final pendant = OmiPendant(
        bleAdapter: adapter,
        persistenceBox: _FakeBox<dynamic>(),
        requestBlePermissions: () async => true,
        requestMicPermission: () async => true,
      );

      await pendant.startPair(scanTimeout: const Duration(milliseconds: 200));

      expect(adapter.startScanCalled, true);
      expect(adapter.stopScanCalled, true);
      expect(adapter.connectedDeviceId, 'AA:BB:CC');
      expect(pendant.info.value.state, PendantState.live);
      expect(pendant.info.value.codec, BleAudioCodec.opus);
      expect(pendant.info.value.deviceId, 'AA:BB:CC');
    });

    test('empty scan timeout → unpaired', () async {
      final adapter = _FakeBleAdapter(scanResultsToEmit: [], servicesToReturn: [], codecBytes: const []);
      final pendant = OmiPendant(
        bleAdapter: adapter,
        persistenceBox: _FakeBox<dynamic>(),
        requestBlePermissions: () async => true,
        requestMicPermission: () async => true,
      );

      await pendant.startPair(scanTimeout: const Duration(milliseconds: 50));

      expect(pendant.info.value.state, PendantState.unpaired);
    });

    test('BLE permission denied → permissionDenied', () async {
      final adapter = _FakeBleAdapter(scanResultsToEmit: [], servicesToReturn: [], codecBytes: const []);
      final pendant = OmiPendant(
        bleAdapter: adapter,
        persistenceBox: _FakeBox<dynamic>(),
        requestBlePermissions: () async => false,
        requestMicPermission: () async => true,
      );

      await pendant.startPair();

      expect(pendant.info.value.state, PendantState.permissionDenied);
      expect(adapter.startScanCalled, false);
    });

    test('mic permission denied → permissionDenied', () async {
      final adapter = _FakeBleAdapter(scanResultsToEmit: [], servicesToReturn: [], codecBytes: const []);
      final pendant = OmiPendant(
        bleAdapter: adapter,
        persistenceBox: _FakeBox<dynamic>(),
        requestBlePermissions: () async => true,
        requestMicPermission: () async => false,
      );

      await pendant.startPair();

      expect(pendant.info.value.state, PendantState.permissionDenied);
    });
  });

  group('OmiPendant characteristic discovery', () {
    test('audio characteristic missing → incompatible', () async {
      final adapter = _FakeBleAdapter(
        scanResultsToEmit: [
          [_omiScanResult()],
        ],
        // Service exists but only with the codec characteristic, missing audio.
        servicesToReturn: [
          BleService(
            uuid: OmiPendant.omiServiceUuid,
            characteristics: [
              BleCharacteristicRef(
                serviceUuid: OmiPendant.omiServiceUuid,
                uuid: OmiPendant.audioCodecCharacteristicUuid,
              ),
            ],
          ),
        ],
        codecBytes: const [20],
      );
      final pendant = OmiPendant(
        bleAdapter: adapter,
        persistenceBox: _FakeBox<dynamic>(),
        requestBlePermissions: () async => true,
        requestMicPermission: () async => true,
      );

      await pendant.startPair(scanTimeout: const Duration(milliseconds: 200));

      expect(pendant.info.value.state, PendantState.incompatible);
    });

    test('codec characteristic missing → incompatible', () async {
      final adapter = _FakeBleAdapter(
        scanResultsToEmit: [
          [_omiScanResult()],
        ],
        servicesToReturn: [
          BleService(
            uuid: OmiPendant.omiServiceUuid,
            characteristics: [
              BleCharacteristicRef(
                serviceUuid: OmiPendant.omiServiceUuid,
                uuid: OmiPendant.audioDataCharacteristicUuid,
              ),
            ],
          ),
        ],
        codecBytes: const [],
      );
      final pendant = OmiPendant(
        bleAdapter: adapter,
        persistenceBox: _FakeBox<dynamic>(),
        requestBlePermissions: () async => true,
        requestMicPermission: () async => true,
      );

      await pendant.startPair(scanTimeout: const Duration(milliseconds: 200));

      expect(pendant.info.value.state, PendantState.incompatible);
    });

    test('unknown codec byte → incompatible (no silent pcm8 fallback)', () async {
      final adapter = _FakeBleAdapter(
        scanResultsToEmit: [
          [_omiScanResult()],
        ],
        servicesToReturn: [_omiAudioService()],
        codecBytes: const [99],
      );
      final pendant = OmiPendant(
        bleAdapter: adapter,
        persistenceBox: _FakeBox<dynamic>(),
        requestBlePermissions: () async => true,
        requestMicPermission: () async => true,
      );

      await pendant.startPair(scanTimeout: const Duration(milliseconds: 200));

      expect(pendant.info.value.state, PendantState.incompatible);
      expect(pendant.info.value.codec, isNull);
    });

    test('codec 1 → pcm8, 20 → opus, 21 → opusFS320', () async {
      Future<BleAudioCodec?> connectWithCodec(int byte) async {
        final adapter = _FakeBleAdapter(
          scanResultsToEmit: [
            [_omiScanResult()],
          ],
          servicesToReturn: [_omiAudioService()],
          codecBytes: [byte],
        );
        final pendant = OmiPendant(
          bleAdapter: adapter,
          persistenceBox: _FakeBox<dynamic>(),
          requestBlePermissions: () async => true,
          requestMicPermission: () async => true,
        );
        await pendant.startPair(scanTimeout: const Duration(milliseconds: 200));
        return pendant.info.value.codec;
      }

      expect(await connectWithCodec(1), BleAudioCodec.pcm8);
      expect(await connectWithCodec(20), BleAudioCodec.opus);
      expect(await connectWithCodec(21), BleAudioCodec.opusFS320);
    });
  });

  group('OmiPendant audio bytes flow', () {
    test('headerless payload via BleDeviceSource.getSocketPayload', () async {
      final adapter = _FakeBleAdapter(
        scanResultsToEmit: [
          [_omiScanResult()],
        ],
        servicesToReturn: [_omiAudioService()],
        codecBytes: const [20],
      );
      final pendant = OmiPendant(
        bleAdapter: adapter,
        persistenceBox: _FakeBox<dynamic>(),
        requestBlePermissions: () async => true,
        requestMicPermission: () async => true,
      );
      await pendant.startPair(scanTimeout: const Duration(milliseconds: 200));
      expect(pendant.info.value.state, PendantState.live);

      final emitted = <List<int>>[];
      final sub = pendant.audioBytes.listen(emitted.add);
      addTearDown(sub.cancel);

      // Three-byte BLE header [packet_id_low, packet_id_high, packet_index]
      // followed by payload bytes.
      final ref = BleCharacteristicRef(
        serviceUuid: OmiPendant.omiServiceUuid,
        uuid: OmiPendant.audioDataCharacteristicUuid,
      );
      adapter.emitAudio(ref, [1, 0, 0, 10, 20, 30]);
      adapter.emitAudio(ref, [2, 0, 1, 40, 50]);
      // Header-only packet: no payload after strip, source returns [].
      adapter.emitAudio(ref, [3, 0, 2]);

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(emitted, [
        [10, 20, 30],
        [40, 50],
      ]);
    });
  });

  group('OmiPendant reconnect', () {
    test('transport disconnect → reconnecting then live', () async {
      final adapter = _FakeBleAdapter(
        scanResultsToEmit: [
          [_omiScanResult()],
        ],
        servicesToReturn: [_omiAudioService()],
        codecBytes: const [20],
      );
      final pendant = OmiPendant(
        bleAdapter: adapter,
        persistenceBox: _FakeBox<dynamic>(),
        requestBlePermissions: () async => true,
        requestMicPermission: () async => true,
        backoffSchedule: const [Duration(milliseconds: 10)],
        giveUpAfter: const Duration(seconds: 30),
      );
      await pendant.startPair(scanTimeout: const Duration(milliseconds: 200));
      expect(pendant.info.value.state, PendantState.live);

      // Trigger transport disconnect.
      adapter.emitDisconnect('AA:BB:CC');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(pendant.info.value.state, PendantState.reconnecting);

      // Reconnect timer fires; backoff schedule of 10ms reconnects.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(pendant.info.value.state, PendantState.live);
    });

    test('30s give-up window → offline with offlineSince', () async {
      final adapter = _FakeBleAdapter(
        scanResultsToEmit: [
          [_omiScanResult()],
        ],
        servicesToReturn: [_omiAudioService()],
        codecBytes: const [20],
      );
      final pendant = OmiPendant(
        bleAdapter: adapter,
        persistenceBox: _FakeBox<dynamic>(),
        requestBlePermissions: () async => true,
        requestMicPermission: () async => true,
        // Compress backoff and give-up to drive the test under tens of ms.
        backoffSchedule: const [Duration(milliseconds: 5)],
        giveUpAfter: const Duration(milliseconds: 30),
      );
      await pendant.startPair(scanTimeout: const Duration(milliseconds: 200));
      expect(pendant.info.value.state, PendantState.live);

      // Make all subsequent connects fail so reconnect can never succeed.
      adapter.throwOnConnect = true;
      adapter.emitDisconnect('AA:BB:CC');

      // Wait past give-up window.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(pendant.info.value.state, PendantState.offline);
      expect(pendant.info.value.offlineSince, isNotNull);
    });
  });

  group('OmiPendant interruption + drop counter', () {
    test('began → interrupted, ended → live, drops increment then reset', () async {
      final adapter = _FakeBleAdapter(
        scanResultsToEmit: [
          [_omiScanResult()],
        ],
        servicesToReturn: [_omiAudioService()],
        codecBytes: const [20],
      );
      final pendant = OmiPendant(
        bleAdapter: adapter,
        persistenceBox: _FakeBox<dynamic>(),
        requestBlePermissions: () async => true,
        requestMicPermission: () async => true,
      );
      await pendant.startPair(scanTimeout: const Duration(milliseconds: 200));
      expect(pendant.info.value.state, PendantState.live);

      pendant.reportInterruption(began: true);
      expect(pendant.info.value.state, PendantState.interrupted);

      // Audio packets while interrupted should bump the drop counter and
      // not flow through.
      final emitted = <List<int>>[];
      final sub = pendant.audioBytes.listen(emitted.add);
      addTearDown(sub.cancel);

      final ref = BleCharacteristicRef(
        serviceUuid: OmiPendant.omiServiceUuid,
        uuid: OmiPendant.audioDataCharacteristicUuid,
      );
      adapter.emitAudio(ref, [1, 0, 0, 10, 20]);
      adapter.emitAudio(ref, [2, 0, 1, 30, 40]);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(emitted, isEmpty);
      expect(pendant.info.value.droppedPacketsLastInterrupt, 2);

      pendant.reportInterruption(began: false);
      expect(pendant.info.value.state, PendantState.live);
      expect(pendant.info.value.droppedPacketsLastInterrupt, 0);
    });
  });

  group('OmiPendant Hive persistence', () {
    test('pair success persists deviceId; auto-reconnect reads it', () async {
      final box = _FakeBox<dynamic>();
      final adapter = _FakeBleAdapter(
        scanResultsToEmit: [
          [_omiScanResult(id: 'XYZ')],
        ],
        servicesToReturn: [_omiAudioService()],
        codecBytes: const [20],
      );
      final pendant = OmiPendant(
        bleAdapter: adapter,
        persistenceBox: box,
        requestBlePermissions: () async => true,
        requestMicPermission: () async => true,
      );

      await pendant.startPair(scanTimeout: const Duration(milliseconds: 200));
      expect(pendant.info.value.state, PendantState.live);
      expect(box.get('lastDeviceId'), 'XYZ');

      // Simulate cold start with a new instance reading the same box.
      final adapter2 = _FakeBleAdapter(
        scanResultsToEmit: [],
        servicesToReturn: [_omiAudioService()],
        codecBytes: const [20],
      );
      final pendant2 = OmiPendant(
        bleAdapter: adapter2,
        persistenceBox: box,
        requestBlePermissions: () async => true,
        requestMicPermission: () async => true,
      );
      await pendant2.tryAutoReconnect();
      expect(adapter2.connectedDeviceId, 'XYZ');
      expect(pendant2.info.value.state, PendantState.live);
    });

    test('auto-reconnect with no stored deviceId is a no-op', () async {
      final box = _FakeBox<dynamic>();
      final adapter = _FakeBleAdapter(scanResultsToEmit: [], servicesToReturn: [], codecBytes: const []);
      final pendant = OmiPendant(
        bleAdapter: adapter,
        persistenceBox: box,
        requestBlePermissions: () async => true,
        requestMicPermission: () async => true,
      );
      await pendant.tryAutoReconnect();
      expect(adapter.connectCalled, false);
      expect(pendant.info.value.state, PendantState.unpaired);
    });
  });
}
