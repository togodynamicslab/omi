import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:hive/hive.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:nooto_v2/audio/codec.dart';
import 'package:nooto_v2/services/audio_sources/ble_device_source.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';

/// Process-level singleton that owns the Omi pendant lifecycle.
///
/// Responsibilities:
///  - Scan with the Omi audio service UUID filter.
///  - Connect, discover services, identify the audio data / audio codec /
///    battery level characteristics.
///  - Read the codec byte and map it to a [BleAudioCodec] (1 → pcm8,
///    20 → opus, 21 → opusFS320). Unknown bytes flip state to
///    [PendantState.incompatible] — never silently fall back to pcm8.
///  - Subscribe to the audio data characteristic, strip the 3-byte BLE
///    header via [BleDeviceSource.getSocketPayload], and emit the headerless
///    payload on the public [audioBytes] stream.
///  - Subscribe to battery level notifications (mirrors legacy
///    `app/lib/providers/device_provider.dart` `performGetBleBatteryLevelListener`).
///  - Run a reconnect loop on transport disconnect with the schedule
///    1s / 2s / 5s / 10s. After 30s elapsed → state → [PendantState.offline]
///    and `offlineSince` is recorded.
///  - Honor AVAudioSession-style interruptions via [reportInterruption]:
///    state → `interrupted` on `began`, → `live` on `ended`. Audio packets
///    arriving while `interrupted` or `reconnecting` are dropped silently;
///    the per-window count surfaces as `droppedPacketsLastInterrupt` and
///    resets to 0 on the next `live` transition.
///  - Persist the last paired pendant id to Hive box `ble.pendant.v1` and
///    auto-attempt connect on cold start.
///
/// Public surface used by [PendantProvider]:
///  - [audioBytes]: `Stream<List<int>>` of headerless audio payloads.
///  - [info]: `ValueListenable<PendantInfo>` carrying state + metadata.
///  - [startPair], [reconnect], [disconnect].
///
/// State machine:
/// `unpaired → permissionDenied → pairing → connecting → incompatible →
///  live → reconnecting → offline → interrupted`. See the design doc:
/// `.gstack/projects/togodynamicslab-omi/matheusoliviera-main-design-wearable-recording-20260503-162510.md`
/// (sections "State machine" and "Resolved Decisions").
class OmiPendant {
  static const String omiServiceUuid = '19b10000-e8f2-537e-4f6c-d104768a1214';
  static const String audioDataCharacteristicUuid = '19b10001-e8f2-537e-4f6c-d104768a1214';
  static const String audioCodecCharacteristicUuid = '19b10002-e8f2-537e-4f6c-d104768a1214';
  static const String batteryServiceUuid = '0000180f-0000-1000-8000-00805f9b34fb';
  static const String batteryCharacteristicUuid = '00002a19-0000-1000-8000-00805f9b34fb';

  /// Hive box name for last-paired pendant state.
  static const String hiveBoxName = 'ble.pendant.v1';
  static const String _hiveKeyDeviceId = 'lastDeviceId';
  static const String _hiveKeyDeviceName = 'lastDeviceName';

  /// Reconnect backoff schedule and total give-up window.
  static const List<Duration> reconnectBackoff = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];
  static const Duration reconnectGiveUpAfter = Duration(seconds: 30);

  /// Process-level singleton — instantiated once at app boot in `main.dart`.
  static OmiPendant? _instance;
  static OmiPendant get instance => _instance ??= OmiPendant._default();

  /// For tests only. Resets the singleton between test cases.
  @visibleForTesting
  static void resetInstanceForTesting(OmiPendant? newInstance) {
    _instance = newInstance;
  }

  /// Test seam — production callers use [OmiPendant.instance] which fills
  /// these defaults from real `flutter_blue_plus` + `Hive`.
  OmiPendant({
    BleAdapter? bleAdapter,
    Box<dynamic>? persistenceBox,
    Future<bool> Function()? requestBlePermissions,
    Future<bool> Function()? requestMicPermission,
    List<Duration>? backoffSchedule,
    Duration? giveUpAfter,
  }) : _ble = bleAdapter ?? RealBleAdapter(),
       _box = persistenceBox,
       _requestBlePermissions = requestBlePermissions ?? _defaultRequestBlePermissions,
       _requestMicPermission = requestMicPermission ?? _defaultRequestMicPermission,
       _backoff = backoffSchedule ?? reconnectBackoff,
       _giveUpAfter = giveUpAfter ?? reconnectGiveUpAfter {
    _info = ValueNotifier<PendantInfo>(const PendantInfo.unpaired());
  }

  factory OmiPendant._default() => OmiPendant();

  final BleAdapter _ble;
  Box<dynamic>? _box;
  final Future<bool> Function() _requestBlePermissions;
  final Future<bool> Function() _requestMicPermission;
  final List<Duration> _backoff;
  final Duration _giveUpAfter;

  late final ValueNotifier<PendantInfo> _info;
  ValueListenable<PendantInfo> get info => _info;

  final StreamController<List<int>> _audioBytes = StreamController<List<int>>.broadcast();
  Stream<List<int>> get audioBytes => _audioBytes.stream;

  // Active connection state.
  String? _connectedDeviceId;
  StreamSubscription<List<int>>? _audioSub;
  StreamSubscription<List<int>>? _batterySub;
  StreamSubscription<bool>? _connectionSub;
  Timer? _reconnectTimer;
  int _backoffIndex = 0;
  DateTime? _reconnectStartedAt;

  // Pluggable BleDeviceSource for header stripping. Created on connect when
  // codec is known.
  BleDeviceSource? _source;

  /// Public start-pair entry. Requests permissions, kicks off scanning, and
  /// connects to the first matching Omi device. UI tap from the pairing
  /// sheet calls this.
  /// True when the most recent [startPair] attempt failed because the iOS
  /// Bluetooth adapter was OFF (not the same as denied permission). The
  /// pendant screen reads this to render a "Turn Bluetooth on in Control
  /// Center" surface card instead of the generic "couldn't find a pendant"
  /// timeout copy. Reset to false at the start of every [startPair].
  bool wasLastPairAttemptBluetoothOff = false;

  Future<void> startPair({Duration scanTimeout = const Duration(seconds: 8)}) async {
    wasLastPairAttemptBluetoothOff = false;
    final blePerm = await _requestBlePermissions();
    final micPerm = await _requestMicPermission();
    if (!blePerm || !micPerm) {
      _setState(PendantState.permissionDenied);
      return;
    }

    _setState(PendantState.pairing);
    try {
      await _ble.startScan(serviceUuids: [omiServiceUuid], timeout: scanTimeout);
      final results = await _ble.scanResults
          .firstWhere((list) => list.any(_matchesOmi), orElse: () => const <BleScanResult>[])
          .timeout(scanTimeout, onTimeout: () => const <BleScanResult>[]);
      await _ble.stopScan();
      BleScanResult? match;
      for (final r in results) {
        if (_matchesOmi(r)) {
          match = r;
          break;
        }
      }
      if (match == null) {
        _setState(PendantState.unpaired);
        return;
      }
      await _connect(match.deviceId, match.deviceName);
    } catch (e, st) {
      debugPrint('[OmiPendant] startPair error: $e\n$st');
      // Detect "Bluetooth is off" specifically — flutter_blue_plus surfaces
      // this as PlatformException(startScan, "bluetooth must be turned on.
      // (CBManagerStateUnknown)" / "(CBManagerStatePoweredOff)"). The screen
      // reads `wasLastPairAttemptBluetoothOff` to render distinct copy.
      final msg = e.toString().toLowerCase();
      if (msg.contains('bluetooth must be turned on') ||
          msg.contains('cbmanagerstateunknown') ||
          msg.contains('cbmanagerstatepoweredoff') ||
          msg.contains('cbmanagerstateunauthorized')) {
        wasLastPairAttemptBluetoothOff = true;
      }
      _setState(PendantState.unpaired);
    }
  }

  /// Auto-attempt to connect to the last paired pendant on cold start.
  Future<void> tryAutoReconnect() async {
    final box = await _resolveBox();
    final id = box.get(_hiveKeyDeviceId) as String?;
    final name = box.get(_hiveKeyDeviceName) as String?;
    if (id == null || id.isEmpty) return;
    final blePerm = await _requestBlePermissions();
    final micPerm = await _requestMicPermission();
    if (!blePerm || !micPerm) {
      _setState(PendantState.permissionDenied);
      return;
    }
    _info.value = _info.value.copyWith(deviceId: id, deviceName: name);
    await _connect(id, name);
  }

  /// Manual reconnect entry — used by status pill tap and voice card tap.
  Future<void> reconnect() async {
    final id = _info.value.deviceId ?? _connectedDeviceId;
    if (id == null) {
      // No prior pair — trigger pairing flow instead.
      await startPair();
      return;
    }
    _cancelReconnectTimer();
    _backoffIndex = 0;
    _reconnectStartedAt = null;
    await _connect(id, _info.value.deviceName);
  }

  /// Tear down the active connection (and persistence). Used when the user
  /// signs out or wipes the pendant pairing.
  Future<void> disconnect() async {
    _cancelReconnectTimer();
    await _audioSub?.cancel();
    _audioSub = null;
    await _batterySub?.cancel();
    _batterySub = null;
    await _connectionSub?.cancel();
    _connectionSub = null;
    final id = _connectedDeviceId;
    if (id != null) {
      try {
        await _ble.disconnectDevice(id);
      } catch (_) {}
    }
    _connectedDeviceId = null;
    _source = null;
    _setState(PendantState.unpaired);
  }

  /// Force the pendant into [PendantState.offline] without tearing down the
  /// device subscriptions. Used by the provider when [SocketStreamer]
  /// emits a terminal event after exhausting reconnects on auth/server
  /// errors — we want the pill / voice card UI to surface offline state
  /// while the BLE link stays alive for an eventual user-initiated retry.
  void forceOffline() {
    _cancelReconnectTimer();
    _info.value = _info.value.copyWith(state: PendantState.offline, offlineSince: DateTime.now());
  }

  /// External hook for AVAudioSession interruption events. Lane D wires this
  /// to a platform channel; tests call directly.
  void reportInterruption({required bool began}) {
    if (began) {
      if (_info.value.state == PendantState.live) {
        _setState(PendantState.interrupted);
      }
    } else {
      if (_info.value.state == PendantState.interrupted) {
        _info.value = _info.value.copyWith(state: PendantState.live, droppedPacketsLastInterrupt: 0);
      }
    }
  }

  /// Total budget from `connecting` start to `live`. If we don't make it in
  /// this window — typically because `setNotifyValue` for the audio CCCD
  /// hangs without an ACK from the pendant, or service discovery stalls —
  /// the user would otherwise stare at the ceremony's "Setting up." beat
  /// indefinitely. Forcing `unpaired` lets the screen surface a clear
  /// ceremony failure ("Something interrupted the connection. Let's try
  /// once more.") instead of an indefinite hang.
  static const Duration connectTimeout = Duration(seconds: 15);

  Future<void> _connect(String deviceId, String? deviceName) async {
    debugPrint('[BLE-DBG] _connect: ENTRY id=$deviceId name=$deviceName');
    _setState(PendantState.connecting, deviceId: deviceId, deviceName: deviceName);
    try {
      await _connectInner(deviceId, deviceName).timeout(connectTimeout);
    } on TimeoutException {
      debugPrint('[BLE-DBG] _connect: TIMEOUT after ${connectTimeout.inSeconds}s — forcing unpaired');
      // Tear down whatever we partially set up, then fail-fast to `unpaired`
      // so the screen's `connecting → unpaired` signal emits a ceremony
      // failure with the BLE error card. Bypasses `_onTransportDisconnect`
      // so we don't enter the reconnect loop during initial pair.
      await _audioSub?.cancel();
      _audioSub = null;
      await _batterySub?.cancel();
      _batterySub = null;
      await _connectionSub?.cancel();
      _connectionSub = null;
      final id = _connectedDeviceId ?? deviceId;
      try {
        await _ble.disconnectDevice(id);
      } catch (_) {}
      _connectedDeviceId = null;
      _source = null;
      _setState(PendantState.unpaired);
    } catch (e, st) {
      debugPrint('[OmiPendant] connect error: $e\n$st');
      _onTransportDisconnect();
    }
  }

  /// Body of the connect flow, extracted so the outer [_connect] can apply a
  /// total-time `.timeout()` budget that catches hung BLE awaits.
  Future<void> _connectInner(String deviceId, String? deviceName) async {
    debugPrint('[BLE-DBG] _connect: calling _ble.connectDevice');
    await _ble.connectDevice(deviceId);
    debugPrint('[BLE-DBG] _connect: connectDevice resolved');
    _connectedDeviceId = deviceId;

    // Wire connection state listener for transport disconnect.
    await _connectionSub?.cancel();
    _connectionSub = _ble.deviceConnectionState(deviceId).listen((connected) {
      if (!connected) {
        _onTransportDisconnect();
      }
    });

    debugPrint('[BLE-DBG] _connect: discoverServices');
    final services = await _ble.discoverServices(deviceId);
    debugPrint('[BLE-DBG] _connect: discoverServices done, ${services.length} services');

    // Find audio + codec characteristics.
    final audio = _findCharacteristic(services, omiServiceUuid, audioDataCharacteristicUuid);
    final codecChar = _findCharacteristic(services, omiServiceUuid, audioCodecCharacteristicUuid);
    if (audio == null || codecChar == null) {
      debugPrint('[BLE-DBG] _connect: incompatible — audio=$audio codec=$codecChar');
      _setState(PendantState.incompatible);
      return;
    }

    // Read codec; unknown byte → incompatible.
    debugPrint('[BLE-DBG] _connect: reading codec characteristic');
    final codecBytes = await _ble.readCharacteristic(deviceId, codecChar);
    final codec = _mapCodecByte(codecBytes);
    debugPrint('[BLE-DBG] _connect: codec bytes=$codecBytes mapped=$codec');
    if (codec == null) {
      _setState(PendantState.incompatible);
      return;
    }

    _source = BleDeviceSource(codec: codec, deviceId: deviceId, deviceModel: 'omi'); // allow-omi: hardware model identifier, internal label

    // Subscribe to audio.
    debugPrint('[BLE-DBG] _connect: setNotifyValue(audio, true)');
    await _audioSub?.cancel();
    await _ble.setNotifyValue(deviceId, audio, true);
    debugPrint('[BLE-DBG] _connect: setNotifyValue done, listening for audio frames');
    _audioSub = _ble.characteristicStream(deviceId, audio).listen(_onAudioBytes);

    // Subscribe to battery (initial read + listener).
    final battery = _findCharacteristic(services, batteryServiceUuid, batteryCharacteristicUuid);
    if (battery != null) {
      try {
        final initial = await _ble.readCharacteristic(deviceId, battery);
        if (initial.isNotEmpty) {
          _info.value = _info.value.copyWith(batteryPercent: initial.first);
        }
        await _batterySub?.cancel();
        await _ble.setNotifyValue(deviceId, battery, true);
        _batterySub = _ble.characteristicStream(deviceId, battery).listen((value) {
          if (value.isNotEmpty) {
            _info.value = _info.value.copyWith(batteryPercent: value.first);
          }
        });
      } catch (e) {
        debugPrint('[OmiPendant] battery setup error: $e');
      }
    }

    // Persist deviceId now that connect succeeded.
    final box = await _resolveBox();
    await box.put(_hiveKeyDeviceId, deviceId);
    if (deviceName != null && deviceName.isNotEmpty) {
      await box.put(_hiveKeyDeviceName, deviceName);
    }

    _backoffIndex = 0;
    _reconnectStartedAt = null;
    debugPrint('[BLE-DBG] _connect: SUCCESS — state → live');
    _info.value = _info.value.copyWith(
      state: PendantState.live,
      deviceId: deviceId,
      deviceName: deviceName,
      codec: codec,
      clearOfflineSince: true,
      droppedPacketsLastInterrupt: 0,
    );
  }

  void _onAudioBytes(List<int> raw) {
    final state = _info.value.state;
    if (state == PendantState.interrupted || state == PendantState.reconnecting) {
      _info.value = _info.value.copyWith(droppedPacketsLastInterrupt: _info.value.droppedPacketsLastInterrupt + 1);
      return;
    }
    if (state != PendantState.live) return;
    final src = _source;
    if (src == null) return;
    final payload = src.getSocketPayload(raw);
    if (payload.isEmpty) return;
    _audioBytes.add(payload);
  }

  void _onTransportDisconnect() {
    final cur = _info.value.state;
    if (cur == PendantState.unpaired || cur == PendantState.permissionDenied || cur == PendantState.incompatible) {
      return;
    }
    _audioSub?.cancel();
    _audioSub = null;
    _batterySub?.cancel();
    _batterySub = null;
    _reconnectStartedAt ??= DateTime.now();

    if (DateTime.now().difference(_reconnectStartedAt!) >= _giveUpAfter) {
      _info.value = _info.value.copyWith(state: PendantState.offline, offlineSince: _reconnectStartedAt);
      _backoffIndex = 0;
      return;
    }

    _setState(PendantState.reconnecting);
    final delay = _backoff[_backoffIndex.clamp(0, _backoff.length - 1)];
    _backoffIndex = (_backoffIndex + 1).clamp(0, _backoff.length - 1);
    _reconnectTimer = Timer(delay, () {
      final id = _connectedDeviceId ?? _info.value.deviceId;
      if (id != null) {
        _connect(id, _info.value.deviceName);
      }
    });
  }

  void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _setState(PendantState s, {String? deviceId, String? deviceName}) {
    _info.value = _info.value.copyWith(state: s, deviceId: deviceId, deviceName: deviceName);
  }

  bool _matchesOmi(BleScanResult r) {
    return r.serviceUuids.any((u) => u.toLowerCase() == omiServiceUuid.toLowerCase());
  }

  BleCharacteristicRef? _findCharacteristic(List<BleService> services, String serviceUuid, String characteristicUuid) {
    for (final s in services) {
      if (s.uuid.toLowerCase() != serviceUuid.toLowerCase()) continue;
      for (final c in s.characteristics) {
        if (c.uuid.toLowerCase() == characteristicUuid.toLowerCase()) {
          return c;
        }
      }
    }
    return null;
  }

  /// Maps the pendant's single codec byte to a [BleAudioCodec]. Returns null
  /// when the byte is empty or unrecognized — caller flips to
  /// [PendantState.incompatible]. Per Resolved Decision in the design doc:
  /// fail fast instead of silently falling back to pcm8.
  static BleAudioCodec? _mapCodecByte(List<int> bytes) {
    if (bytes.isEmpty) return null;
    switch (bytes.first) {
      case 1:
        return BleAudioCodec.pcm8;
      case 20:
        return BleAudioCodec.opus;
      case 21:
        return BleAudioCodec.opusFS320;
      default:
        return null;
    }
  }

  Future<Box<dynamic>> _resolveBox() async {
    if (_box != null) return _box!;
    if (Hive.isBoxOpen(hiveBoxName)) {
      _box = Hive.box<dynamic>(hiveBoxName);
    } else {
      _box = await Hive.openBox<dynamic>(hiveBoxName);
    }
    return _box!;
  }

  Future<void> dispose() async {
    _cancelReconnectTimer();
    await _audioSub?.cancel();
    await _batterySub?.cancel();
    await _connectionSub?.cancel();
    await _audioBytes.close();
    _info.dispose();
  }
}

/// Default permission flow for BLE on iOS/Android.
Future<bool> _defaultRequestBlePermissions() async {
  if (Platform.isIOS || Platform.isMacOS) {
    final s = await Permission.bluetooth.request();
    return s.isGranted || s.isLimited;
  }
  // Android 12+: scan + connect.
  final scan = await Permission.bluetoothScan.request();
  final connect = await Permission.bluetoothConnect.request();
  return scan.isGranted && connect.isGranted;
}

Future<bool> _defaultRequestMicPermission() async {
  final s = await Permission.microphone.request();
  return s.isGranted;
}

/// Test-only opaque shape for a discovered BLE peripheral.
class BleScanResult {
  BleScanResult({required this.deviceId, required this.deviceName, required this.serviceUuids, this.rssi});
  final String deviceId;
  final String deviceName;
  final List<String> serviceUuids;
  final int? rssi;
}

/// Test-only opaque service descriptor.
class BleService {
  BleService({required this.uuid, required this.characteristics});
  final String uuid;
  final List<BleCharacteristicRef> characteristics;
}

/// Test-only opaque characteristic descriptor.
class BleCharacteristicRef {
  BleCharacteristicRef({required this.serviceUuid, required this.uuid});
  final String serviceUuid;
  final String uuid;
}

/// Abstraction around `flutter_blue_plus` so [OmiPendant] is testable
/// without spinning up a real BLE stack. Production wraps the real plugin
/// in [RealBleAdapter]; tests inject a fake via the constructor seam.
abstract class BleAdapter {
  Future<void> startScan({required List<String> serviceUuids, required Duration timeout});
  Future<void> stopScan();
  Stream<List<BleScanResult>> get scanResults;

  Future<void> connectDevice(String deviceId);
  Future<void> disconnectDevice(String deviceId);
  Stream<bool> deviceConnectionState(String deviceId);

  Future<List<BleService>> discoverServices(String deviceId);
  Future<List<int>> readCharacteristic(String deviceId, BleCharacteristicRef ref);
  Future<void> setNotifyValue(String deviceId, BleCharacteristicRef ref, bool notify);
  Stream<List<int>> characteristicStream(String deviceId, BleCharacteristicRef ref);
}

/// Production [BleAdapter] backed by `flutter_blue_plus` static surface.
class RealBleAdapter implements BleAdapter {
  @override
  Future<void> startScan({required List<String> serviceUuids, required Duration timeout}) {
    return fbp.FlutterBluePlus.startScan(withServices: serviceUuids.map((u) => fbp.Guid(u)).toList(), timeout: timeout);
  }

  @override
  Future<void> stopScan() => fbp.FlutterBluePlus.stopScan();

  @override
  Stream<List<BleScanResult>> get scanResults => fbp.FlutterBluePlus.scanResults.map(
    (list) => list
        .map(
          (r) => BleScanResult(
            deviceId: r.device.remoteId.str,
            deviceName: r.device.platformName,
            serviceUuids: r.advertisementData.serviceUuids.map((g) => g.toString()).toList(),
            rssi: r.rssi,
          ),
        )
        .toList(),
  );

  @override
  Future<void> connectDevice(String deviceId) {
    final dev = fbp.BluetoothDevice.fromId(deviceId);
    return dev.connect(autoConnect: false);
  }

  @override
  Future<void> disconnectDevice(String deviceId) {
    final dev = fbp.BluetoothDevice.fromId(deviceId);
    return dev.disconnect();
  }

  @override
  Stream<bool> deviceConnectionState(String deviceId) {
    final dev = fbp.BluetoothDevice.fromId(deviceId);
    return dev.connectionState.map((s) => s == fbp.BluetoothConnectionState.connected);
  }

  @override
  Future<List<BleService>> discoverServices(String deviceId) async {
    final dev = fbp.BluetoothDevice.fromId(deviceId);
    final services = await dev.discoverServices();
    return services
        .map(
          (s) => BleService(
            uuid: s.serviceUuid.toString(),
            characteristics: s.characteristics
                .map(
                  (c) => BleCharacteristicRef(
                    serviceUuid: s.serviceUuid.toString(),
                    uuid: c.characteristicUuid.toString(),
                  ),
                )
                .toList(),
          ),
        )
        .toList();
  }

  @override
  Future<List<int>> readCharacteristic(String deviceId, BleCharacteristicRef ref) async {
    final char = _resolve(deviceId, ref);
    if (char == null) return const [];
    return char.read();
  }

  @override
  Future<void> setNotifyValue(String deviceId, BleCharacteristicRef ref, bool notify) async {
    final char = _resolve(deviceId, ref);
    if (char == null) return;
    await char.setNotifyValue(notify);
  }

  @override
  Stream<List<int>> characteristicStream(String deviceId, BleCharacteristicRef ref) {
    final char = _resolve(deviceId, ref);
    if (char == null) return const Stream.empty();
    return char.onValueReceived;
  }

  fbp.BluetoothCharacteristic? _resolve(String deviceId, BleCharacteristicRef ref) {
    final dev = fbp.BluetoothDevice.fromId(deviceId);
    for (final s in dev.servicesList) {
      if (s.serviceUuid.toString().toLowerCase() != ref.serviceUuid.toLowerCase()) continue;
      for (final c in s.characteristics) {
        if (c.characteristicUuid.toString().toLowerCase() == ref.uuid.toLowerCase()) {
          return c;
        }
      }
    }
    return null;
  }
}
