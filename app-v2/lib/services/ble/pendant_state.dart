import 'package:nooto_v2/audio/codec.dart';

/// Pendant connection state machine for the Omi BLE pendant.
///
/// This is the locked public surface that both the service stack
/// (`OmiPendant`, `pendant_provider`) and the UI (`status_pill`,
/// `connect_pendant_voice_card`, `pairing_sheet`) consume. Lanes C and D
/// land in parallel against this enum without depending on each other.
///
/// Transitions are documented in the wearable recording design doc.
/// Source of truth:
/// `.gstack/projects/togodynamicslab-omi/matheusoliviera-main-design-wearable-recording-20260503-162510.md`
/// (see "State machine" section).
///
/// Summary of transitions:
///
/// - `unpaired` → `pairing` when the user taps "Pair" and BLE/mic permissions are granted.
/// - `unpaired` → `permissionDenied` when the user denies BLE or mic permission.
/// - `pairing` → `connecting` after pair succeeds and characteristic discovery starts.
/// - `connecting` → `live` when the audio characteristic emits its first frame.
/// - `connecting` → `incompatible` when the device does not expose Omi audio
///   or the codec byte is not in [BleAudioCodec].
/// - `live` → `reconnecting` on BLE drop / pendant power-off (transport disconnect).
/// - `live` → `interrupted` on AVAudioSession interruption (incoming call, Siri, etc.).
/// - `interrupted` → `live` when the interruption ends.
/// - `reconnecting` → `live` when reconnect succeeds.
/// - `reconnecting` → `offline` after 30s with no successful reconnect.
/// - `offline` → `connecting` when the user taps the pill / voice card,
///   or when the pendant is detected by a slow background scan.
enum PendantState {
  unpaired,
  permissionDenied,
  pairing,
  connecting,
  incompatible,
  live,
  reconnecting,
  offline,
  interrupted,
}

/// Immutable snapshot of pendant connection details exposed by the provider layer.
///
/// `PendantInfo` is the public shape the provider exposes to UI widgets
/// (status pill, voice card, pairing sheet). It carries enough metadata
/// for the UI to render every row of the state × surface matrix in the
/// design doc without poking into provider internals.
class PendantInfo {
  /// Current state in the [PendantState] machine.
  final PendantState state;

  /// BLE device id of the last-known pendant (persisted across cold starts).
  /// Null until the user has paired at least once.
  final String? deviceId;

  /// Human-readable name advertised by the pendant. Null until first connect.
  final String? deviceName;

  /// Last-known battery percentage (0-100). Null if not yet read.
  /// Read but not rendered in v0; pill may surface in v0.5.
  final int? batteryPercent;

  /// Codec negotiated by the pendant on connect. Null until first connect.
  final BleAudioCodec? codec;

  /// Wall-clock timestamp at which the pendant transitioned into `offline`.
  /// Used to compute "Offline since {time}" pill labels and to gate the
  /// late-pair voice card (visible at ≥ 5 minutes offline).
  final DateTime? offlineSince;

  /// Number of BLE audio packets dropped during the most recent
  /// `interrupted` or `reconnecting` window. Resets on transition back to
  /// `live`. Debug-readable in v0; not surfaced in the UI.
  final int droppedPacketsLastInterrupt;

  const PendantInfo({
    required this.state,
    this.deviceId,
    this.deviceName,
    this.batteryPercent,
    this.codec,
    this.offlineSince,
    this.droppedPacketsLastInterrupt = 0,
  });

  /// Initial info before any pairing has been attempted.
  const PendantInfo.unpaired() : this(state: PendantState.unpaired);

  PendantInfo copyWith({
    PendantState? state,
    String? deviceId,
    String? deviceName,
    int? batteryPercent,
    BleAudioCodec? codec,
    DateTime? offlineSince,
    int? droppedPacketsLastInterrupt,
    bool clearOfflineSince = false,
    bool clearBattery = false,
    bool clearCodec = false,
    bool clearDevice = false,
  }) {
    return PendantInfo(
      state: state ?? this.state,
      deviceId: clearDevice ? null : (deviceId ?? this.deviceId),
      deviceName: clearDevice ? null : (deviceName ?? this.deviceName),
      batteryPercent: clearBattery ? null : (batteryPercent ?? this.batteryPercent),
      codec: clearCodec ? null : (codec ?? this.codec),
      offlineSince: clearOfflineSince ? null : (offlineSince ?? this.offlineSince),
      droppedPacketsLastInterrupt: droppedPacketsLastInterrupt ?? this.droppedPacketsLastInterrupt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PendantInfo &&
        other.state == state &&
        other.deviceId == deviceId &&
        other.deviceName == deviceName &&
        other.batteryPercent == batteryPercent &&
        other.codec == codec &&
        other.offlineSince == offlineSince &&
        other.droppedPacketsLastInterrupt == droppedPacketsLastInterrupt;
  }

  @override
  int get hashCode => Object.hash(
        state,
        deviceId,
        deviceName,
        batteryPercent,
        codec,
        offlineSince,
        droppedPacketsLastInterrupt,
      );

  @override
  String toString() =>
      'PendantInfo(state: $state, deviceId: $deviceId, deviceName: $deviceName, '
      'batteryPercent: $batteryPercent, codec: $codec, offlineSince: $offlineSince, '
      'droppedPacketsLastInterrupt: $droppedPacketsLastInterrupt)';
}
