import 'package:flutter/widgets.dart';

import 'package:nooto_v2/apps/apps_provider.dart';

/// Bridges Flutter's [AppLifecycleState.resumed] event to attention-driven
/// integration syncs. When the app comes to the foreground, fires
/// [AppsProvider.maybeSyncIfStale] for each registered app id so Plan,
/// brief, and other surfaces show fresh upstream state by the time the user
/// looks at them — without forcing them to tap "Sync now".
///
/// Stays a thin coordinator: each [AppsProvider.maybeSyncIfStale] call
/// already carries its own staleness gate and in-flight guard. The
/// debouncer here exists for a different reason: iOS fires
/// `AppLifecycleState.resumed` on every quick app switch (control center
/// swipe, notification preview, Spotlight). Without coalescing, ten such
/// events in 30s would each call into the provider — most would short-
/// circuit on staleness, but the wasted notifyListeners + accessor reads
/// add up. The 30s window matches the planned server-side rate-limit
/// window (PR1b), so behavior stays consistent when the backend gate lands.
class AppLifecycleObserver with WidgetsBindingObserver {
  AppLifecycleObserver({
    required AppsProvider apps,
    required this.appIds,
    this.minAge = const Duration(seconds: 60),
    this.debounce = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _apps = apps,
       _clock = clock ?? DateTime.now;

  /// App ids to refresh on resume. Today: `['nooto-jira']`. As Notion /
  /// Linear / GitHub integrations land, append their ids — the observer
  /// loops over them in registration order.
  final List<String> appIds;

  /// Skip the sync if the cached `lastSyncedAt` is younger than this.
  final Duration minAge;

  /// Coalesce window for [AppLifecycleState.resumed] events. Matches the
  /// planned PR1b backend Redis lock window so server + client agree on
  /// "freshly synced" semantics.
  final Duration debounce;

  final AppsProvider _apps;
  final DateTime Function() _clock;
  DateTime? _lastFiredAt;

  /// Attaches the observer. Idempotent — Flutter's binding tolerates
  /// repeated `addObserver` calls but we deduplicate to keep tests simple.
  void attach() {
    if (_attached) return;
    WidgetsBinding.instance.addObserver(this);
    _attached = true;
  }

  /// Detaches the observer. Safe to call when not attached.
  void detach() {
    if (!_attached) return;
    WidgetsBinding.instance.removeObserver(this);
    _attached = false;
  }

  bool _attached = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final now = _clock();
    if (_lastFiredAt != null && now.difference(_lastFiredAt!) < debounce) return;
    _lastFiredAt = now;
    for (final id in appIds) {
      // Fire-and-forget. maybeSyncIfStale swallows its own errors.
      _apps.maybeSyncIfStale(id, minAge);
    }
  }
}
