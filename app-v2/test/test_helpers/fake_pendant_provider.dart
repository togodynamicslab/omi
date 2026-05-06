import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/services/ble/omi_pendant.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/services/ble/socket_streamer.dart';

/// In-memory test double for [PendantProvider].
///
/// Lets widget tests inject any state in the State × surface matrix without
/// spinning up the real BLE stack, WebSocket, or Firebase. Mutate via
/// [setInfo]; the provider notifies listeners exactly once per call.
///
/// `startPair` and `reconnect` are no-ops by default but record their call
/// counts so tests can assert that taps wired through the real provider
/// surface (pill, sheet, voice card, onboarding turn) reach the expected
/// method.
///
/// Extends Lane C's concrete [PendantProvider]. Constructs lazy [OmiPendant]
/// and [SocketStreamer] defaults — neither performs eager BLE/network/Firebase
/// work at construction, so widget tests don't need platform plumbing.
/// Overrides `info`, `startPair`, and `reconnect` to bypass the underlying
/// pendant and serve test snapshots directly.
class FakePendantProvider extends PendantProvider {
  FakePendantProvider({PendantInfo? initial})
    : _info = initial ?? const PendantInfo.unpaired(),
      // Skip the audio-activity periodic Timer — flutter_test treats
      // unfinished periodic timers as a fail signal under pumpAndSettle.
      super(pendant: OmiPendant(), socket: SocketStreamer(), startAudioActivityTracker: false);

  PendantInfo _info;
  int startPairCallCount = 0;
  int reconnectCallCount = 0;
  int disconnectCallCount = 0;

  @override
  PendantInfo get info => _info;

  /// Replace the current snapshot and notify listeners. Identity-equal
  /// updates are dropped to mirror typical `ChangeNotifier` ergonomics.
  void setInfo(PendantInfo next) {
    if (_info == next) return;
    _info = next;
    notifyListeners();
  }

  /// Convenience setter — replace just the [PendantState] and re-notify.
  void setState(PendantState state) {
    setInfo(
      PendantInfo(
        state: state,
        deviceId: _info.deviceId,
        deviceName: _info.deviceName,
        batteryPercent: _info.batteryPercent,
        codec: _info.codec,
        offlineSince: _info.offlineSince,
        droppedPacketsLastInterrupt: _info.droppedPacketsLastInterrupt,
      ),
    );
  }

  @override
  Future<void> startPair() async {
    startPairCallCount++;
  }

  /// Test seam — set to true to simulate the iOS "Bluetooth is off" failure
  /// path so the screen renders the BluetoothOff surface card.
  bool fakeWasLastPairAttemptBluetoothOff = false;

  @override
  bool get wasLastPairAttemptBluetoothOff => fakeWasLastPairAttemptBluetoothOff;

  @override
  Future<void> reconnect() async {
    reconnectCallCount++;
  }

  @override
  Future<void> disconnect() async {
    disconnectCallCount++;
  }
}
