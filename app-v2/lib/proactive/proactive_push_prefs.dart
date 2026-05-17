import 'package:hive/hive.dart';

/// User-configurable knobs for the proactive Reminders push.
///
/// Lives in its own box so we can rev push log + prefs independently and so
/// the Settings → Native Sync screen can read defaults without booting the
/// service.
///
/// Defaults are chosen for "safe by default" — see Decision 4A in the
/// design doc. The feature is OFF until the user opts in on the
/// pre-permission activation screen.
class ProactivePushPrefs {
  ProactivePushPrefs._();

  static const String box = 'proactive_push_prefs.v1';

  static const String _kEnabled = 'enabled';
  static const String _kThreshold = 'confidence_threshold';
  static const String _kDailyBudget = 'daily_budget';
  static const String _kMutedSources = 'muted_sources';
  static const String _kFirstSeenAt = 'first_seen_at';

  /// Default confidence threshold. Matches the "strong intent" tier in the
  /// extractor prompt — explicit task requests (>=0.95) and hard commitments
  /// with deadlines (>=0.80) push automatically, weaker inferences stay in
  /// the in-app list. The user can drop this in Settings.
  static const double defaultThreshold = 0.80;

  /// Default daily push budget. Holds the user's "this isn't a firehose"
  /// expectation even on a chatty day. User-configurable.
  static const int defaultDailyBudget = 8;

  static Box<dynamic> get _box => Hive.box<dynamic>(box);

  // Master toggle — false until the user opts in.

  static bool get enabled => _box.get(_kEnabled, defaultValue: false) as bool;
  static Future<void> setEnabled(bool value) => _box.put(_kEnabled, value);

  // Confidence threshold.

  static double get confidenceThreshold {
    final raw = _box.get(_kThreshold, defaultValue: defaultThreshold);
    if (raw is num) return raw.toDouble().clamp(0.0, 1.0);
    return defaultThreshold;
  }

  static Future<void> setConfidenceThreshold(double value) =>
      _box.put(_kThreshold, value.clamp(0.0, 1.0));

  // Daily budget.

  static int get dailyBudget {
    final raw = _box.get(_kDailyBudget, defaultValue: defaultDailyBudget);
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return defaultDailyBudget;
  }

  static Future<void> setDailyBudget(int value) =>
      _box.put(_kDailyBudget, value.clamp(0, 999));

  // Muted external sources. A muted source's items never get pushed (e.g.
  // user said "no thanks, Jira owns its own reminders").

  static Set<String> get mutedSources {
    final raw = _box.get(_kMutedSources, defaultValue: const <String>[]);
    if (raw is List) return raw.map((e) => e.toString()).toSet();
    return <String>{};
  }

  static Future<void> setMutedSources(Set<String> sources) =>
      _box.put(_kMutedSources, sources.toList());

  static Future<void> muteSource(String source) async {
    final s = mutedSources..add(source);
    await setMutedSources(s);
  }

  static Future<void> unmuteSource(String source) async {
    final s = mutedSources..remove(source);
    await setMutedSources(s);
  }

  // First-seen timestamp. The activation gate uses this to avoid back-filling
  // the user's existing 47 open items into Reminders on the first run — only
  // items whose createdAt > firstSeenAt are eligible for push.

  static DateTime? get firstSeenAt {
    final raw = _box.get(_kFirstSeenAt);
    if (raw is String) return DateTime.tryParse(raw)?.toUtc();
    return null;
  }

  static Future<void> stampFirstSeenNow() =>
      _box.put(_kFirstSeenAt, DateTime.now().toUtc().toIso8601String());

  static Future<void> clearAll() => _box.clear();
}
