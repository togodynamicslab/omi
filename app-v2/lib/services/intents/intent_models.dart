/// Dart-side mirror of the on-device Foundation Models intent schema.
///
/// The native bridge (`ios/Runner/IntentBridge.swift`) pre-serializes the
/// parsed intent to JSON and also returns the dispatch outcome + latency.
/// We only need a thin Dart representation for the UI to switch on.
///
/// Per the design doc at
/// `~/.gstack/projects/togodynamicslab-omi/matheusoliviera-main-design-poc-on-device-intent-*.md`,
/// the PoC validated four intent kinds on iOS 26.2 simulator:
///   - set_alarm     → Shortcuts URL (user-created NootoSetAlarm)
///   - start_timer   → Shortcuts URL (user-created NootoStartTimer)
///   - add_event     → EventKit EKEvent.save (public API)
///   - make_reminder → EventKit EKReminder.save (public API)
///   - unknown       → no-op, surface reason
library;

enum IntentKind {
  setAlarm,
  startTimer,
  addEvent,
  makeReminder,
  unknown;

  static IntentKind fromWire(String value) => switch (value) {
        'set_alarm' => IntentKind.setAlarm,
        'start_timer' => IntentKind.startTimer,
        'add_event' => IntentKind.addEvent,
        'make_reminder' => IntentKind.makeReminder,
        _ => IntentKind.unknown,
      };

  String get displayLabel => switch (this) {
        IntentKind.setAlarm => 'Alarm',
        IntentKind.startTimer => 'Timer',
        IntentKind.addEvent => 'Event',
        IntentKind.makeReminder => 'Reminder',
        IntentKind.unknown => 'Unknown',
      };
}

enum DispatchStatus {
  success,
  noop,
  failed;

  static DispatchStatus fromWire(String value) => switch (value) {
        'success' => DispatchStatus.success,
        'failed' => DispatchStatus.failed,
        _ => DispatchStatus.noop,
      };
}

/// Result of a single parse+dispatch pass.
class IntentResult {
  /// Pretty-printed JSON of the parsed `NootoIntent` (for the result panel).
  final String parsedJson;

  /// Discriminator on the parsed kind. UI uses this to pick the right
  /// confirmation copy ("Alarm set", "Event added to Calendar", etc.).
  final IntentKind intentKind;

  /// Whether the system action fired, was a no-op (unknown intent), or failed.
  final DispatchStatus status;

  /// Populated when [status] is failed: human-readable reason from the
  /// native dispatcher (e.g. "Calendar access denied", "EKReminder save
  /// failed: ...").
  final String? failureReason;

  /// LLM round-trip in milliseconds (parse only; dispatch is fast and not
  /// timed separately).
  final int latencyMs;

  /// True when Foundation Models' safety classifier refused the input.
  /// This happens on some "X minute timer" phrasings — see the design doc's
  /// iOS Simulator E2E Findings section.
  final bool blockedBySafetyClassifier;

  const IntentResult({
    required this.parsedJson,
    required this.intentKind,
    required this.status,
    required this.failureReason,
    required this.latencyMs,
    required this.blockedBySafetyClassifier,
  });

  factory IntentResult.fromWire(Map<dynamic, dynamic> map) {
    return IntentResult(
      parsedJson: (map['parsedJson'] as String?) ?? '',
      intentKind: IntentKind.fromWire((map['intentKind'] as String?) ?? 'unknown'),
      status: DispatchStatus.fromWire((map['dispatchStatus'] as String?) ?? 'noop'),
      failureReason: map['dispatchReason'] as String?,
      latencyMs: (map['latencyMs'] as int?) ?? 0,
      blockedBySafetyClassifier: (map['blockedBySafetyClassifier'] as bool?) ?? false,
    );
  }
}

/// Result of the `checkAvailability` ping. Used by the entry point to gate
/// the sheet — if Foundation Models isn't available, we show a friendly
/// reason rather than letting the user type into a broken pipe.
class IntentAvailability {
  final bool available;

  /// Populated when [available] is false: "This device isn't Apple
  /// Intelligence-capable...", "Apple Intelligence is off...", etc.
  final String? reason;

  const IntentAvailability({required this.available, required this.reason});

  factory IntentAvailability.fromWire(Map<dynamic, dynamic> map) {
    return IntentAvailability(
      available: (map['available'] as bool?) ?? false,
      reason: map['reason'] as String?,
    );
  }
}
