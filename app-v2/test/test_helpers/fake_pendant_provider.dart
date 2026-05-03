import 'package:nooto_v2/providers/pendant_provider_contract.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';

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
class FakePendantProvider extends PendantProvider {
  FakePendantProvider({PendantInfo? initial}) : _info = initial ?? const PendantInfo.unpaired();

  PendantInfo _info;
  int startPairCallCount = 0;
  int reconnectCallCount = 0;

  @override
  PendantInfo get info => _info;

  /// Replace the current snapshot and notify listeners. Identity-equal
  /// updates are dropped to mirror typical `ChangeNotifier` ergonomics.
  void setInfo(PendantInfo next) {
    if (_info == next) return;
    _info = next;
    notifyListeners();
  }

  @override
  Future<void> startPair() async {
    startPairCallCount++;
  }

  @override
  Future<void> reconnect() async {
    reconnectCallCount++;
  }
}
