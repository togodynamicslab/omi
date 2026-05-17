import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:nooto_v2/providers/action_items_provider.dart';
import 'package:nooto_v2/services/intents/intent_dispatcher.dart';
import 'package:nooto_v2/services/intents/intent_models.dart';
import 'package:nooto_v2/proactive/gate_decision.dart';
import 'package:nooto_v2/proactive/proactive_push_prefs.dart';
import 'package:nooto_v2/proactive/proactive_push_storage.dart';

/// Diffs the live [ActionItemsProvider] state, runs each new item through
/// the gate, and fires successful pushes via [IntentDispatcher.dispatchStructured]
/// → iOS Reminders.
///
/// Failure mode: a `pushFailed` decision does NOT add the item to the
/// in-memory `previouslySeenIds` snapshot, so the next foreground retries
/// it automatically (Decision 14A in the eng-review). The retry is bounded
/// by the daily budget and the gate's other skips.
///
/// Reverse-check is invoked separately by the foreground hook
/// ([runReverseCheck]) — bulk-fetches all `pushed` reminders and marks any
/// that have disappeared from the user's Reminders app as `userDeleted`,
/// making them permanently ineligible.
///
/// Lifecycle: a single instance per app process. Attach to the provider via
/// [attach] in main.dart (after the box is open and the provider is in the
/// tree). The listener holds a strong reference for the process lifetime;
/// there is no detach API.
class ProactivePushService with WidgetsBindingObserver {
  ProactivePushService({
    required ActionItemsProvider actionItems,
    IntentDispatcher? dispatcher,
    DateTime Function()? nowOverride,
    bool Function()? isIosOverride,
  })  : _actionItems = actionItems,
        _dispatcher = dispatcher ?? IntentDispatcher(),
        _now = nowOverride ?? DateTime.now,
        _isIosFn = isIosOverride ?? _defaultIsIos;

  final ActionItemsProvider _actionItems;
  final IntentDispatcher _dispatcher;
  final DateTime Function() _now;
  final bool Function() _isIosFn;

  bool _attached = false;
  bool _ticking = false;
  bool _reverseChecking = false;

  /// Ids we've already evaluated in this process. Survivor of the in-memory
  /// dedup; the Hive log is the cross-process source of truth. A
  /// `pushFailed` outcome intentionally does NOT add to this set so the
  /// next provider tick retries the item.
  final Set<String> _previouslySeenIds = <String>{};

  void attach() {
    if (_attached) return;
    _attached = true;
    _actionItems.addListener(_onProviderChanged);
    // App-resume hook → reverse-check. Bundles cleanly with the existing
    // AppLifecycleObserver pattern (Jira refresh on resume) so users see
    // the result of any deletions they made in Reminders the next time
    // they bring Nooto forward.
    WidgetsBinding.instance.addObserver(this);
    // Kick once in case items have already been hydrated before attach.
    scheduleMicrotask(_onProviderChanged);
    // Also reverse-check on cold-start once the boxes are warm. Safe even
    // when the log is empty — runReverseCheck early-returns.
    scheduleMicrotask(runReverseCheck);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    scheduleMicrotask(runReverseCheck);
    scheduleMicrotask(_onProviderChanged);
  }

  Future<void> _onProviderChanged() async {
    if (_ticking) return;
    _ticking = true;
    try {
      await _scan();
    } finally {
      _ticking = false;
    }
  }

  Future<void> _scan() async {
    if (!ProactivePushPrefs.enabled) return;
    if (!_isIos) return;

    // Stamp first-seen on the first scan AFTER the user enabled the feature.
    // Items predating this anchor never push (avoids back-filling 47 open
    // items into Reminders on day one).
    if (ProactivePushPrefs.firstSeenAt == null) {
      await ProactivePushPrefs.stampFirstSeenNow();
    }
    final activation = ProactivePushPrefs.firstSeenAt;

    final candidates = _actionItems.items
        .where((item) => !item.completed)
        .where((item) => !_previouslySeenIds.contains(item.id))
        .toList();

    for (final item in candidates) {
      final decision = _evaluate(item, activation: activation);
      debugPrint('[ProactivePush] ${item.id} -> ${decision.wire}');
      switch (decision) {
        case GateDecision.ok:
          final pushed = await _push(item);
          if (!pushed) {
            // Decision 14A: do NOT snapshot the id on push failure — the
            // next provider tick retries.
            continue;
          }
          _previouslySeenIds.add(item.id);
        case GateDecision.featureDisabled:
        case GateDecision.remindersUnavailable:
          // Don't snapshot — these are environment problems that may
          // resolve (permission granted, toggle flipped on). Re-evaluate
          // on the next tick.
          continue;
        case GateDecision.dailyBudgetExceeded:
          // Don't snapshot — budget resets at local midnight and we want
          // tomorrow's first tick to find these items unseen.
          continue;
        case GateDecision.pushFailed:
          // Defensive; _push() handles the non-snapshot itself. Falling
          // through here doesn't change behavior.
          continue;
        case GateDecision.alreadyPushed:
        case GateDecision.userPreviouslyDeleted:
        case GateDecision.externalSource:
        case GateDecision.sourceMuted:
        case GateDecision.noConfidence:
        case GateDecision.belowThreshold:
        case GateDecision.predatesActivation:
          // Stable skips — snapshot so we don't re-evaluate next tick.
          _previouslySeenIds.add(item.id);
      }
    }
  }

  GateDecision _evaluate(ActionItem item, {required DateTime? activation}) {
    if (!ProactivePushPrefs.enabled) return GateDecision.featureDisabled;

    final logRow = ProactivePushBoxes.read(item.id);
    if (logRow != null) {
      if (logRow.kind == ProactivePushKind.pushed) return GateDecision.alreadyPushed;
      if (logRow.kind == ProactivePushKind.userDeleted) return GateDecision.userPreviouslyDeleted;
    }

    if (item.externalSource != null) {
      // External-sourced items are owned by the source tool. The mute set
      // is a separate user signal; either path skips push.
      final src = item.externalSource!.source;
      if (ProactivePushPrefs.mutedSources.contains(src)) {
        return GateDecision.sourceMuted;
      }
      return GateDecision.externalSource;
    }

    if (activation != null && item.createdAt != null) {
      final created = item.createdAt!.toUtc();
      if (created.isBefore(activation)) return GateDecision.predatesActivation;
    }

    final c = item.confidence;
    if (c == null) return GateDecision.noConfidence;
    if (c < ProactivePushPrefs.confidenceThreshold) return GateDecision.belowThreshold;

    final localToday = DateTime(_now().year, _now().month, _now().day);
    final pushedToday = ProactivePushBoxes.pushedCountOnLocalDate(localToday);
    if (pushedToday >= ProactivePushPrefs.dailyBudget) {
      return GateDecision.dailyBudgetExceeded;
    }

    return GateDecision.ok;
  }

  /// Returns true on success (item was pushed + logged). False on dispatcher
  /// failure — the caller leaves the item unsnapshotted so the next tick
  /// retries.
  Future<bool> _push(ActionItem item) async {
    final outcome = await _dispatcher.dispatchStructured(
      kind: 'make_reminder',
      title: item.description,
      due: item.dueAt?.toUtc().toIso8601String(),
    );
    if (outcome.status != DispatchStatus.success) {
      debugPrint(
        '[ProactivePush] push failed for ${item.id}: ${outcome.reason ?? "no reason"}',
      );
      return false;
    }
    final identifier = outcome.identifier;
    if (identifier == null || identifier.isEmpty) {
      // The bridge claimed success but didn't return an identifier — record
      // the push anyway so we don't loop, but reverse-check won't be able
      // to find this row.
      debugPrint('[ProactivePush] success without identifier for ${item.id}');
    }
    await ProactivePushBoxes.recordPushed(
      actionItemId: item.id,
      reminderIdentifier: identifier ?? '',
      description: item.description,
      confidence: item.confidence,
    );
    return true;
  }

  /// Bulk reverse-check: ask iOS for the EKReminder for each tracked
  /// identifier; rows whose reminder is missing get a `userDeleted` log
  /// entry so we never re-push them.
  ///
  /// Wired to the foreground hook (alongside Jira attention-driven refresh)
  /// so users see the result immediately when they bring the app forward.
  ///
  /// The actual fetchReminders call lives in a native Swift extension —
  /// this method is the Dart-side orchestrator. When the bridge isn't yet
  /// wired (TODO), this is a no-op.
  Future<void> runReverseCheck({
    Future<Set<String>> Function(List<String> identifiers)? existsCheck,
  }) async {
    if (!_isIos) return;
    if (!ProactivePushPrefs.enabled) return;
    if (_reverseChecking) return;
    _reverseChecking = true;
    try {
      final rows = ProactivePushBoxes.pushedRowsForReverseCheck();
      if (rows.isEmpty) return;
      final ids = rows.map((r) => r.reminderIdentifier!).toList();
      final present = await (existsCheck ?? _defaultExistsCheck)(ids);
      for (final row in rows) {
        if (present.contains(row.reminderIdentifier)) continue;
        debugPrint(
          '[ProactivePush] reverse-check: ${row.actionItemId} missing in Reminders -> userDeleted',
        );
        await ProactivePushBoxes.recordUserDeleted(
          actionItemId: row.actionItemId,
          priorReminderIdentifier: row.reminderIdentifier,
          priorDescription: row.description,
          priorConfidence: row.confidence,
        );
      }
    } finally {
      _reverseChecking = false;
    }
  }

  /// Default reverse-check: hits the native `existingReminderIdentifiers`
  /// channel which fetches the user's Reminders and intersects with the
  /// requested identifiers. Tests can pass a stub via [runReverseCheck]'s
  /// [existsCheck] parameter to drive the deletion path.
  Future<Set<String>> _defaultExistsCheck(List<String> ids) =>
      _dispatcher.existingReminderIdentifiers(ids);

  bool get _isIos => _isIosFn();

  static bool _defaultIsIos() {
    if (kIsWeb) return false;
    try {
      return Platform.isIOS;
    } catch (_) {
      return false;
    }
  }
}
