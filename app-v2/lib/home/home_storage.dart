import 'package:hive/hive.dart';

/// Hive box names for the Companion Stream Home.
///
/// All three are opened in `main()` before `runApp` (parallel via `Future.wait`).
/// They persist across launches and survive `OnboardingChatProvider.reset()`
/// EXCEPT when reset explicitly wipes them via [clearAll].
class HomeBoxes {
  HomeBoxes._();

  /// Serialized `CompanionCard.toJson()` rows, keyed by `id`. Persists the
  /// rendered stream so cards don't vanish on app restart. TTL enforcement
  /// happens on Home foreground.
  static const String cards = 'home.cards.v1';

  /// Cached morning-brief LLM response, keyed by `YYYY-MM-DD` (PR2 scope).
  /// Re-fetched only when the date key rolls over.
  static const String brief = 'home.brief.v1';

  /// Card-action history rows: `{id, action, ts, until?}`. Generators consult
  /// this box and skip emitting any card whose `id` already has a `dismiss`
  /// row. Snooze rows include an `until` timestamp.
  static const String actions = 'home.actions.v1';

  /// Wipes the rendered stream, the cached brief, and the action history so
  /// the next Home build behaves like a cold start. Used by the debug "Reset
  /// onboarding" flow to give a true clean slate.
  static Future<void> clearAll() async {
    await Future.wait([
      Hive.box<Map>(cards).clear(),
      Hive.box<Map>(brief).clear(),
      Hive.box<Map>(actions).clear(),
    ]);
  }
}

/// One-shot migration that sweeps orphaned action-log entries left behind by
/// the brief-as-coordinator redesign (2026-05-05). When `JiraStuckIssuesCard`
/// and `TodayCard` were retired, dismiss/snooze rows keyed by their card ids
/// (`jira-stuck-YYYY-MM-DD::dismiss`, `today-YYYY-MM-DD::accept`, etc.) became
/// unreadable — no card class deserializes those kinds anymore, so they
/// accumulate forever without affecting UI.
///
/// Idempotent: running twice on the same device is a no-op (second pass
/// finds zero matching keys). Safe to run on every app launch from `main()`.
///
/// Returns the number of keys deleted (test signal).
Future<int> sweepRetiredHomeActionLogEntries() async {
  final box = Hive.box<Map>(HomeBoxes.actions);
  final orphans = <dynamic>[];
  for (final key in box.keys) {
    if (key is! String) continue;
    if (key.startsWith('jira-stuck-') || key.startsWith('today:')) {
      orphans.add(key);
    }
  }
  if (orphans.isNotEmpty) await box.deleteAll(orphans);
  return orphans.length;
}
