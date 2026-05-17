import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:nooto_v2/services/intents/intent_models.dart';

/// Thin wrapper around the iOS-side `IntentDispatchBridge` (see
/// `ios/Runner/IntentDispatchBridge.swift`).
///
/// Always registered, independent of iOS version. Takes a structured intent
/// (kind + fields) and fires the system action via EventKit. Used by the
/// cloud-parser path when Foundation Models isn't available — the parser
/// produces the structured fields elsewhere (cloud LLM), then this dispatcher
/// does the actual Calendar / Reminders write.
class IntentDispatcher {
  IntentDispatcher();

  static const MethodChannel _channel = MethodChannel('com.nooto.intent_dispatcher');

  /// Fires the system action for a parsed intent. Returns the dispatch
  /// status, optional failure reason, and the saved item's identifier
  /// (EKReminder.calendarItemIdentifier for make_reminder/set_alarm — null
  /// otherwise). Never throws — non-iOS / unknown kinds resolve to a
  /// `failed` status with a descriptive reason so the caller can render
  /// uniformly. The identifier is what the proactive-push path uses for
  /// dedup and reverse-checking deletion in iOS Reminders.
  Future<({DispatchStatus status, String? reason, String? identifier})> dispatchStructured({
    required String kind,
    String? time,
    int? seconds,
    String? recurrence,
    String? label,
    String? title,
    String? start,
    int? durationMinutes,
    String? due,
    String? location,
    String? notes,
  }) async {
    if (!_isSupportedPlatform) {
      return (status: DispatchStatus.failed, reason: 'On-device dispatch is iOS-only.', identifier: null);
    }
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'dispatchStructured',
        {
          'kind': kind,
          if (time != null) 'time': time,
          if (seconds != null) 'seconds': seconds,
          if (recurrence != null) 'recurrence': recurrence,
          if (label != null) 'label': label,
          if (title != null) 'title': title,
          if (start != null) 'start': start,
          if (durationMinutes != null) 'durationMinutes': durationMinutes,
          if (due != null) 'due': due,
          if (location != null) 'location': location,
          if (notes != null) 'notes': notes,
        },
      );
      if (result == null) {
        return (status: DispatchStatus.failed, reason: 'native returned no payload', identifier: null);
      }
      final status = DispatchStatus.fromWire((result['status'] as String?) ?? 'failed');
      return (
        status: status,
        reason: result['reason'] as String?,
        identifier: result['identifier'] as String?,
      );
    } on PlatformException catch (e) {
      debugPrint('[IntentDispatcher] dispatchStructured failed: $e');
      return (status: DispatchStatus.failed, reason: e.message ?? 'platform error', identifier: null);
    } on MissingPluginException {
      return (
        status: DispatchStatus.failed,
        reason: 'Native intent dispatcher is not registered.',
        identifier: null,
      );
    }
  }

  /// Reads upcoming EventKit events (next [daysAhead] days, all granted
  /// calendars) and returns them as a JSON-shaped list ready to inline into
  /// a chat request's `device_context.apple_calendar` field. The backend
  /// agent's `<device_context>` system block renders these alongside its
  /// Google Calendar tool, so calendar questions get both sources.
  ///
  /// On non-iOS / missing-plugin / permission-denied we return an empty
  /// list — the agent then falls back to whatever cloud calendars it has
  /// tools for.
  Future<List<Map<String, dynamic>>> fetchUpcomingCalendarEvents({int daysAhead = 7}) async {
    if (!_isSupportedPlatform) return const [];
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'fetchUpcomingEvents',
        {'daysAhead': daysAhead},
      );
      if (result == null) return const [];
      final raw = result['events'];
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList(growable: false);
    } on PlatformException catch (e) {
      debugPrint('[IntentDispatcher] fetchUpcomingEvents failed: $e');
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Reverse-check seam for the proactive-push service. Returns the subset
  /// of [identifiers] that still have a matching `EKReminder` in the user's
  /// Reminders database. Anything missing means the user deleted it in
  /// the Reminders app — the caller (ProactivePushService) records a
  /// `userDeleted` state so the item never gets re-pushed.
  ///
  /// On non-iOS / missing-plugin / permission-denied we return the input
  /// set unchanged so nothing gets marked as deleted by accident.
  Future<Set<String>> existingReminderIdentifiers(List<String> identifiers) async {
    if (!_isSupportedPlatform) return identifiers.toSet();
    if (identifiers.isEmpty) return <String>{};
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'existingReminderIdentifiers',
        {'identifiers': identifiers},
      );
      if (result == null) return identifiers.toSet();
      final present = result['present'];
      if (present is List) {
        return present.map((e) => e.toString()).toSet();
      }
      return identifiers.toSet();
    } on PlatformException catch (e) {
      debugPrint('[IntentDispatcher] existingReminderIdentifiers failed: $e');
      return identifiers.toSet();
    } on MissingPluginException {
      return identifiers.toSet();
    }
  }

  bool get _isSupportedPlatform {
    if (kIsWeb) return false;
    return Platform.isIOS;
  }
}
