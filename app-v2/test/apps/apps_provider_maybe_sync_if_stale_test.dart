import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:nooto_v2/apps/apps_provider.dart';
import 'package:nooto_v2/apps/apps_storage.dart';
import 'package:nooto_v2/services/api_client.dart';

ApiClient _api(MockClient mock) => ApiClient(
  httpClient: mock,
  getIdToken: ({bool forceRefresh = false}) async => 'tok',
  signOut: () async {},
  baseUrl: 'https://example.test/',
);

/// Catalog fixture with nooto-jira present + external_integration set so
/// the provider's integration-id lookup resolves.
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

/// Mock that counts every POST to /v1/integrations/nooto-jira/sync-now and
/// answers with a 200 stamped at [responseTs] (default: a fresh "just now").
({MockClient client, int Function() syncCalls}) _syncCountingMock({required String responseTs}) {
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
      return http.Response(jsonEncode({'synced': 2, 'errors': 0, 'last_synced_at': responseTs}), 200);
    }
    return http.Response('not found', 404);
  });
  return (client: c, syncCalls: () => count);
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('apps_provider_maybe_sync_test');
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

  test('no prior sync — fires syncNow', () async {
    final mock = _syncCountingMock(responseTs: DateTime.now().toUtc().toIso8601String());
    final provider = AppsProvider(client: _api(mock.client));
    await provider.load();

    expect(provider.lastSyncedAt('nooto-jira'), isNull, reason: 'precondition');

    await provider.maybeSyncIfStale('nooto-jira', const Duration(seconds: 60));

    expect(mock.syncCalls(), 1);
    expect(provider.lastSyncedAt('nooto-jira'), isNotNull);
  });

  test('stale (last sync > minAge ago) — fires syncNow', () async {
    final mock = _syncCountingMock(responseTs: DateTime.now().toUtc().toIso8601String());
    final provider = AppsProvider(client: _api(mock.client));
    await provider.load();

    // Seed an old lastSyncedAt by running syncNow against a stale stamp,
    // then immediately call maybeSyncIfStale with a 60s window.
    final stale = DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String();
    final mockStale = _syncCountingMock(responseTs: stale);
    final providerStale = AppsProvider(client: _api(mockStale.client));
    await providerStale.load();
    await providerStale.syncNow('nooto-jira'); // primes lastSyncedAt to "5 min ago"
    expect(mockStale.syncCalls(), 1);

    await providerStale.maybeSyncIfStale('nooto-jira', const Duration(seconds: 60));

    // Second call goes through because cached ts is older than minAge.
    expect(mockStale.syncCalls(), 2);
  });

  test('fresh (last sync within minAge) — no-op', () async {
    final mock = _syncCountingMock(responseTs: DateTime.now().toUtc().toIso8601String());
    final provider = AppsProvider(client: _api(mock.client));
    await provider.load();
    await provider.syncNow('nooto-jira'); // primes lastSyncedAt to now
    expect(mock.syncCalls(), 1);

    await provider.maybeSyncIfStale('nooto-jira', const Duration(seconds: 60));

    // No second call — cached ts is well within the 60s window.
    expect(mock.syncCalls(), 1);
  });

  test('appId not in catalog — silent no-op (no exception, no call)', () async {
    final mock = _syncCountingMock(responseTs: DateTime.now().toUtc().toIso8601String());
    final provider = AppsProvider(client: _api(mock.client));
    await provider.load();

    await provider.maybeSyncIfStale('not-a-real-app', const Duration(seconds: 60));

    expect(mock.syncCalls(), 0, reason: 'unknown app should never reach the route');
  });

  test('syncNow returning an error code — error swallowed (no rethrow)', () async {
    final mock = MockClient((req) async {
      if (req.url.path == '/v2/apps') {
        return http.Response(jsonEncode(_catalog()), 200);
      }
      if (req.url.path == '/v1/apps/enabled') {
        return http.Response(jsonEncode(const ['nooto-jira']), 200);
      }
      if (req.url.path == '/v1/integrations/nooto-jira/sync-now') {
        return http.Response('boom', 500); // network/error path
      }
      return http.Response('not found', 404);
    });
    final provider = AppsProvider(client: _api(mock));
    await provider.load();

    // Should NOT throw — lifecycle/tab-focus path must stay silent on errors.
    await expectLater(provider.maybeSyncIfStale('nooto-jira', const Duration(seconds: 60)), completes);
  });
}
