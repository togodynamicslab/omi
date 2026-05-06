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
  PendantProvider({OmiPendant? pendant, SocketStreamer? socket, bool startAudioActivityTracker = true})
    : _pendant = pendant ?? OmiPendant.instance,
      _socket = socket ?? SocketStreamer() {
    _pendant.info.addListener(_onInfoChanged);
    _audioSub = _pendant.audioBytes.listen((bytes) {
      _socket.send(bytes);
      _audioByteAccumulator += bytes.length;
    });
    _eventsSub = _socket.events.listen(_onSocketEvent);
    _info = _pendant.info.value;
    // Tick audio activity at 4Hz in production. Tests pass false so the
    // periodic Timer doesn't leak into pumpAndSettle / pumpFrames; tests
    // that need a non-zero audioActivity value can poke `audioActivity.value`
    // directly via the FakePendantProvider seam.
    if (startAudioActivityTracker) {
      _audioActivityTimer = Timer.periodic(_audioActivityWindow, _tickAudioActivity);
    }
  }

  final OmiPendant _pendant;
  final SocketStreamer _socket;

  PendantInfo _info = const PendantInfo.unpaired();
  PendantInfo get info => _info;

  StreamSubscription<List<int>>? _audioSub;
  StreamSubscription<SocketEvent>? _eventsSub;
  PendantState? _lastState;

  // ---------------------------------------------------------------------------
  // Audio activity (0..1) — proxy for "the mic is hearing something."
  //
  // Surfaced for the post-pair settled UI so the breathing orb / particle
  // field can pulse with what the pendant is capturing (per 2026-05-05
  // dogfood: "visualize the waves of the mic so feel it alive"). We don't
  // have an Opus decoder on-device, so this approximates amplitude with
  // byte-rate: Opus DTX cuts bytes during silence, so byte-rate-per-window
  // is a reasonable "is speech happening" signal even without sample
  // amplitude. Smoothed with exponential decay so the visual doesn't
  // jitter every 250ms.
  // ---------------------------------------------------------------------------

  /// Audio activity 0..1, ticked at 4Hz from the BLE audio stream byte rate.
  /// Listeners (e.g. PendantOrb in settled mode) read this to drive
  /// audio-reactive scale/alpha.
  final ValueNotifier<double> audioActivity = ValueNotifier<double>(0);

  // (Live transcript was briefly fed from backend Deepgram via the
  // SocketTranscript event piping. Reverted 2026-05-05: per dogfood, the
  // UX preview takes the on-device "Pendant → BLE Opus → iOS STT" path
  // owned by `PendantSttProvider`. The SocketTranscript event class still
  // exists in `socket_streamer.dart` for future consumers but nothing
  // listens to it here.)

  static const Duration _audioActivityWindow = Duration(milliseconds: 250);
  // Opus speech ≈ 4-5 KB/s, so ~1.0-1.25 KB / 250ms window. Cap at 1500
  // bytes for headroom on louder/varying bitrate streams.
  static const double _audioActivityMaxBytesPerWindow = 1500;

  int _audioByteAccumulator = 0;
  Timer? _audioActivityTimer;

  void _tickAudioActivity(Timer _) {
    final raw = (_audioByteAccumulator / _audioActivityMaxBytesPerWindow).clamp(0.0, 1.0);
    // Exponential smoothing — 0.4 weight on history makes ramp-up + decay
    // span roughly 4 windows (1s) instead of jumping window-to-window.
    audioActivity.value = 0.4 * audioActivity.value + 0.6 * raw;
    _audioByteAccumulator = 0;
  }

  /// Public action — used by the pairing sheet's Pair button and the
  /// onboarding chat turn.
  Future<void> startPair() => _pendant.startPair();

  /// Mirrors `OmiPendant.wasLastPairAttemptBluetoothOff`. The screen reads
  /// this on `pairing → unpaired` transitions to differentiate "Bluetooth
  /// off" from "no pendant nearby" and pick the right surface-card copy.
  bool get wasLastPairAttemptBluetoothOff => _pendant.wasLastPairAttemptBluetoothOff;

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
    // SocketTranscript is intentionally unhandled — see comment near
    // `liveTranscript` field. UX preview pipes via PendantSttProvider.
  }

  @override
  void dispose() {
    _pendant.info.removeListener(_onInfoChanged);
    _audioSub?.cancel();
    _eventsSub?.cancel();
    _audioActivityTimer?.cancel();
    audioActivity.dispose();
    super.dispose();
  }
}
