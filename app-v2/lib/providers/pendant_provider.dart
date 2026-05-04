import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:nooto_v2/services/ble/omi_pendant.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/services/ble/socket_streamer.dart';

/// Thin [ChangeNotifier] adapter wiring the process-level [OmiPendant] and
/// [SocketStreamer] singletons into the v2 Provider tree.
///
/// Responsibilities:
///  - Mirror [OmiPendant.info] into a [ChangeNotifier] so widgets like the
///    status pill and the connect-pendant voice card can subscribe via
///    `context.watch<PendantProvider>().info`.
///  - On `OmiPendant` state == `live`, connect [SocketStreamer] with the
///    negotiated codec.
///  - Forward audio bytes from [OmiPendant.audioBytes] to
///    [SocketStreamer.send] (dropping while `interrupted`/`reconnecting`
///    is the pendant's job — this provider just trusts the pendant's gate).
///  - On [SocketTerminal] events, transition pendant state to `offline`.
///
/// Lifecycle: `OmiPendant` and `SocketStreamer` are process-level
/// singletons (per Decision 1C in /plan-eng-review). `PendantProvider` is a
/// thin adapter, instantiated once at app boot — it does not own the
/// underlying singletons and does not dispose them.
class PendantProvider extends ChangeNotifier {
  PendantProvider({OmiPendant? pendant, SocketStreamer? socket})
    : _pendant = pendant ?? OmiPendant.instance,
      _socket = socket ?? SocketStreamer() {
    _pendant.info.addListener(_onInfoChanged);
    _audioSub = _pendant.audioBytes.listen(_socket.send);
    _eventsSub = _socket.events.listen(_onSocketEvent);
    _info = _pendant.info.value;
  }

  final OmiPendant _pendant;
  final SocketStreamer _socket;

  PendantInfo _info = const PendantInfo.unpaired();
  PendantInfo get info => _info;

  StreamSubscription<List<int>>? _audioSub;
  StreamSubscription<SocketEvent>? _eventsSub;
  PendantState? _lastState;

  /// Public action — used by the pairing sheet's Pair button and the
  /// onboarding chat turn.
  Future<void> startPair() => _pendant.startPair();

  /// Public action — used by the status pill and the voice card on tap
  /// when the pendant is offline.
  Future<void> reconnect() => _pendant.reconnect();

  /// Public action — used by the dedicated pendant screen's "Disconnect"
  /// button. Thin pass-through to [OmiPendant.disconnect]; the provider's
  /// `_onInfoChanged` listener handles the socket teardown side effects.
  Future<void> disconnect() => _pendant.disconnect();

  /// Cold-start hook. Should be called once at app boot after Hive is
  /// open. Reads the last-paired device id and attempts to auto-connect.
  Future<void> bootstrap() => _pendant.tryAutoReconnect();

  /// Surface for AVAudioSession-style interruption. Lane D wires a platform
  /// channel; tests call directly.
  void reportInterruption({required bool began}) => _pendant.reportInterruption(began: began);

  /// Phone-mic vs pendant arbitration entry point. Suspends the pendant
  /// stream for [duration], then resumes by issuing a reconnect. Per
  /// Resolved Decision in the design doc, pendant wins by default; phone
  /// mic features must request a pause.
  Future<void> pauseFor(Duration duration) async {
    if (_info.state != PendantState.live) return;
    await _pendant.disconnect();
    await Future<void>.delayed(duration);
    await _pendant.reconnect();
  }

  void _onInfoChanged() {
    final next = _pendant.info.value;
    final prev = _info;
    final prevState = _lastState;
    _info = next;
    _lastState = next.state;

    if (next.state == PendantState.live && prevState != PendantState.live) {
      final codec = next.codec;
      if (codec != null && !_socket.isOpen) {
        unawaited(_socket.connect(codec: codec));
      }
    }

    // On leaving `live` for a teardown state: close the socket. We keep it
    // open during `interrupted` and `reconnecting` so a quick recovery
    // skips the upgrade round-trip (audio is dropped client-side anyway).
    if (prevState == PendantState.live &&
        (next.state == PendantState.unpaired ||
            next.state == PendantState.offline ||
            next.state == PendantState.permissionDenied ||
            next.state == PendantState.incompatible)) {
      unawaited(_socket.close());
    }

    // Skip widget rebuilds when the only change is the drop counter — that
    // ticks on every dropped audio packet during `interrupted`/`reconnecting`
    // and the UI doesn't render it in v0 (see Open Question #1 in design doc).
    if (_onlyDropCounterChanged(prev, next)) return;
    notifyListeners();
  }

  static bool _onlyDropCounterChanged(PendantInfo a, PendantInfo b) {
    return a.state == b.state &&
        a.deviceId == b.deviceId &&
        a.deviceName == b.deviceName &&
        a.batteryPercent == b.batteryPercent &&
        a.codec == b.codec &&
        a.offlineSince == b.offlineSince &&
        a.droppedPacketsLastInterrupt != b.droppedPacketsLastInterrupt;
  }

  void _onSocketEvent(SocketEvent e) {
    if (e is SocketTerminal) {
      // The streamer gave up after exhausting retries on auth or server
      // errors. Per the design doc state machine, this surfaces to the
      // user as `offline` (pill turns red, voice card appears at >5min).
      _pendant.forceOffline();
    }
  }

  @override
  void dispose() {
    _pendant.info.removeListener(_onInfoChanged);
    _audioSub?.cancel();
    _eventsSub?.cancel();
    super.dispose();
  }
}
