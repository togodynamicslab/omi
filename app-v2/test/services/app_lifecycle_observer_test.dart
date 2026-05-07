import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:nooto_v2/apps/apps_provider.dart';
import 'package:nooto_v2/apps/apps_storage.dart';
import 'package:nooto_v2/services/api_client.dart';
import 'package:nooto_v2/services/app_lifecycle_observer.dart';

ApiClient _api(MockClient mock) => ApiClient(
  httpClient: mock,
  getIdToken: ({bool forceRefresh = false}) async => 'tok',
  signOut: () async {},
  baseUrl: 'https://example.test/',
);

Map<String, dynamic> _catalog() => {
  'groups': [
    {
      'capability': {'id': 'integrations', 'title': 'Integrations'},
      'data': [
        {
          'id': 'nooto-jira',
          'name': 'Jira',
          'description': 'Sync tickets',
          'image': '',
          'enabled': true,
          'installs': 1,
          'capabilities': const ['integration'],
          'external_integration': {'app_home_url': 'https://jira.test/home'},
        },
      ],
    },
  ],
  'meta': {'capabilities': const [], 'groupCount': 1, 'limit': 20, 'offset': 0},
};

({MockClient client, int Function() syncCalls}) _mock() {
  var count = 0;
  final c = MockClient((req) async {
    if (req.url.path == '/v2/apps') {
      return http.Response(jsonEncode(_catalog()), 200);
    }
    if (req.url.path == '/v1/apps/enabled') {
      return http.Response(jsonEncode(const ['nooto-jira']), 200);
    }
    if (req.url.path == '/v1/integrations/nooto-jira/sync-now') {
      count += 1;
      return http.Response(
        jsonEncode({'synced': 1, 'errors': 0, 'last_synced_at': DateTime.now().toUtc().toIso8601String()}),
        200,
      );
    }
    return http.Response('not found', 404);
  });
  return (client: c, syncCalls: () => count);
}

/// Manual clock so debounce assertions don't depend on wall time.
class _Clock {
  DateTime now = DateTime(2026, 5, 7, 12, 0, 0);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('lifecycle_observer_test');
    Hive.init(tempDir.path);
  });

  setUp(() async {
    if (!Hive.isBoxOpen(AppsBoxes.prefs)) {
      await Hive.openBox<Map>(AppsBoxes.prefs);
    }
    await Hive.box<Map>(AppsBoxes.prefs).clear();
  });

  tearDownAll(() async {
    await Hive.deleteFromDisk();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('resumed event triggers maybeSyncIfStale for each registered app', () async {
    final mock = _mock();
    final apps = AppsProvider(client: _api(mock.client));
    await apps.load();
    final observer = AppLifecycleObserver(apps: apps, appIds: const ['nooto-jira']);

    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    // maybeSyncIfStale is fire-and-forget; let the microtask queue flush.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(mock.syncCalls(), 1);
  });

  test('paused / inactive / hidden / detached events do not trigger sync', () async {
    final mock = _mock();
    final apps = AppsProvider(client: _api(mock.client));
    await apps.load();
    final observer = AppLifecycleObserver(apps: apps, appIds: const ['nooto-jira']);

    observer.didChangeAppLifecycleState(AppLifecycleState.paused);
    observer.didChangeAppLifecycleState(AppLifecycleState.inactive);
    observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
    observer.didChangeAppLifecycleState(AppLifecycleState.detached);
    await Future<void>.delayed(Duration.zero);

    expect(mock.syncCalls(), 0);
  });

  test('debounce: rapid resume events within window collapse to one sync', () async {
    final mock = _mock();
    final apps = AppsProvider(client: _api(mock.client));
    await apps.load();
    final clock = _Clock();
    final observer = AppLifecycleObserver(
      apps: apps,
      appIds: const ['nooto-jira'],
      debounce: const Duration(seconds: 30),
      // Use 0 minAge so the staleness gate doesn't also intervene — we want
      // to verify the OBSERVER's debounce specifically, not the provider's.
      minAge: Duration.zero,
      clock: clock.call,
    );

    observer.didChangeAppLifecycleState(AppLifecycleState.resumed); // t=0
    clock.advance(const Duration(seconds: 5));
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed); // t=5
    clock.advance(const Duration(seconds: 10));
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed); // t=15
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(mock.syncCalls(), 1, reason: 'second + third resumes inside the 30s window must be dropped');
  });

  test('debounce releases after window — next resume fires again', () async {
    final mock = _mock();
    final apps = AppsProvider(client: _api(mock.client));
    await apps.load();
    final clock = _Clock();
    final observer = AppLifecycleObserver(
      apps: apps,
      appIds: const ['nooto-jira'],
      debounce: const Duration(seconds: 30),
      minAge: Duration.zero,
      clock: clock.call,
    );

    observer.didChangeAppLifecycleState(AppLifecycleState.resumed); // t=0
    // Settle the first sync fully so AppsProvider._syncingIds clears
    // before the second resume tries to call syncNow.
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(mock.syncCalls(), 1, reason: 'first resume must complete before next assertion');

    clock.advance(const Duration(seconds: 31));
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed); // t=31, fresh window
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(mock.syncCalls(), 2);
  });

  test('attach/detach are idempotent', () {
    final mock = _mock();
    final apps = AppsProvider(client: _api(mock.client));
    final observer = AppLifecycleObserver(apps: apps, appIds: const ['nooto-jira']);

    // Multiple attach calls should not throw or double-register.
    observer.attach();
    observer.attach();
    observer.detach();
    observer.detach();
  });
}
