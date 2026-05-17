import 'package:hive/hive.dart';

/// Hive box for the proactive action-item → iOS Reminders push log.
///
/// Per the eng-review (Decision 7A) we only log outcomes that affect what the
/// user sees: a successful push to Reminders, and a user-driven deletion in
/// the Reminders app (caught by the reverse-check). Gate skips (low
/// confidence, external source, etc.) are NOT persisted — they're high-volume
/// noise and recomputable from the current ActionItem state.
///
/// One row per `actionItemId` (latest wins). The state machine:
///
///   (no row)         --push-->   pushed
///   pushed           --reverse-check missing-->   userDeleted
///   userDeleted      (terminal — never re-push)
///
/// Row schema (Map keys):
///   * `kind`        — "pushed" | "user_deleted"
///   * `ts`          — ISO8601 UTC timestamp of the event
///   * `reminderIdentifier`  — EKReminder.calendarItemIdentifier (pushed only)
///   * `description` — snapshot of the action item description at push time
///                     (so "Recently pushed" can render even after the item
///                     is mutated/deleted server-side)
///   * `confidence`  — snapshot of the confidence at push time (for debug UI)
class ProactivePushBoxes {
  ProactivePushBoxes._();

  /// Polymorphic state-log keyed by action-item id. Cleared by debug reset.
  static const String log = 'proactive_push.v1';

  static Box<Map> get _box => Hive.box<Map>(log);

  /// Returns the most recent row for [actionItemId], or null if we've never
  /// seen it (it's a candidate for push).
  static ProactivePushRow? read(String actionItemId) {
    final raw = _box.get(actionItemId);
    if (raw == null) return null;
    return ProactivePushRow.fromMap(actionItemId, Map<String, dynamic>.from(raw));
  }

  /// All rows in the log, sorted by ts desc. Used by the Settings → Native
  /// Sync "Recently pushed" sub-screen. Cheap enough — the daily budget caps
  /// total volume.
  static List<ProactivePushRow> allSortedDesc() {
    final rows = <ProactivePushRow>[];
    for (final key in _box.keys) {
      final raw = _box.get(key);
      if (raw == null) continue;
      rows.add(ProactivePushRow.fromMap(key as String, Map<String, dynamic>.from(raw)));
    }
    rows.sort((a, b) => b.ts.compareTo(a.ts));
    return rows;
  }

  /// Records a successful push. Overwrites any prior row for the id (the
  /// only realistic prior state is null — gate prevents pushing over
  /// "userDeleted").
  static Future<void> recordPushed({
    required String actionItemId,
    required String reminderIdentifier,
    required String description,
    required double? confidence,
  }) async {
    await _box.put(actionItemId, {
      'kind': ProactivePushKind.pushed.wire,
      'ts': DateTime.now().toUtc().toIso8601String(),
      'reminderIdentifier': reminderIdentifier,
      'description': description,
      'confidence': confidence,
    });
  }

  /// Records that the user deleted the reminder for this item (reverse-check
  /// found the EKReminder missing). Terminal state — the gate refuses to
  /// re-push.
  static Future<void> recordUserDeleted({
    required String actionItemId,
    required String? priorReminderIdentifier,
    required String? priorDescription,
    required double? priorConfidence,
  }) async {
    await _box.put(actionItemId, {
      'kind': ProactivePushKind.userDeleted.wire,
      'ts': DateTime.now().toUtc().toIso8601String(),
      'reminderIdentifier': priorReminderIdentifier,
      'description': priorDescription,
      'confidence': priorConfidence,
    });
  }

  /// Count of `pushed` rows with ts on the given local-date. The proactive
  /// service uses this as the input to the daily-budget gate. Local time so
  /// the cap aligns with the user's day, not UTC midnight.
  static int pushedCountOnLocalDate(DateTime localDate) {
    final start = DateTime(localDate.year, localDate.month, localDate.day);
    final end = start.add(const Duration(days: 1));
    var count = 0;
    for (final key in _box.keys) {
      final raw = _box.get(key);
      if (raw == null) continue;
      final row = ProactivePushRow.fromMap(key as String, Map<String, dynamic>.from(raw));
      if (row.kind != ProactivePushKind.pushed) continue;
      final local = row.ts.toLocal();
      if (!local.isBefore(start) && local.isBefore(end)) count += 1;
    }
    return count;
  }

  /// Returns all `pushed`-kind rows whose `reminderIdentifier` is non-null.
  /// Used by the reverse-check to figure out which identifiers to ask iOS
  /// for. Excludes `userDeleted` rows (we already know those are gone).
  static List<ProactivePushRow> pushedRowsForReverseCheck() {
    final rows = <ProactivePushRow>[];
    for (final key in _box.keys) {
      final raw = _box.get(key);
      if (raw == null) continue;
      final row = ProactivePushRow.fromMap(key as String, Map<String, dynamic>.from(raw));
      if (row.kind != ProactivePushKind.pushed) continue;
      if (row.reminderIdentifier == null) continue;
      rows.add(row);
    }
    return rows;
  }

  /// Used by the debug "Reset onboarding" flow.
  static Future<void> clearAll() => _box.clear();
}

enum ProactivePushKind {
  pushed('pushed'),
  userDeleted('user_deleted');

  const ProactivePushKind(this.wire);
  final String wire;

  static ProactivePushKind fromWire(String? wire) {
    for (final v in values) {
      if (v.wire == wire) return v;
    }
    return ProactivePushKind.pushed;
  }
}

class ProactivePushRow {
  const ProactivePushRow({
    required this.actionItemId,
    required this.kind,
    required this.ts,
    this.reminderIdentifier,
    this.description,
    this.confidence,
  });

  final String actionItemId;
  final ProactivePushKind kind;
  final DateTime ts;
  final String? reminderIdentifier;
  final String? description;
  final double? confidence;

  factory ProactivePushRow.fromMap(String actionItemId, Map<String, dynamic> map) {
    final tsRaw = map['ts'] as String?;
    final ts = tsRaw != null ? DateTime.tryParse(tsRaw)?.toUtc() : null;
    final rawConfidence = map['confidence'];
    return ProactivePushRow(
      actionItemId: actionItemId,
      kind: ProactivePushKind.fromWire(map['kind'] as String?),
      ts: ts ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      reminderIdentifier: map['reminderIdentifier'] as String?,
      description: map['description'] as String?,
      confidence: rawConfidence is num ? rawConfidence.toDouble() : null,
    );
  }
}
