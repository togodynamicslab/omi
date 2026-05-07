import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:nooto_v2/apps/apps_provider.dart';
import 'package:nooto_v2/services/api_client.dart';
import 'package:nooto_v2/shell/shell_screen.dart';

ApiClient _api(MockClient mock) => ApiClient(
  httpClient: mock,
  getIdToken: ({bool forceRefresh = false}) async => 'tok',
  signOut: () async {},
  baseUrl: 'https://example.test/',
);

/// Spy provider — overrides only the method the helper calls so the test
/// stays a true unit test (no Hive, no catalog, no /v2/apps round-trip).
class _SpyApps extends AppsProvider {
  _SpyApps({required super.client});

  final List<({String appId, Duration minAge})> calls = [];

  @override
  Future<void> maybeSyncIfStale(String appId, Duration minAge) async {
    calls.add((appId: appId, minAge: minAge));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('non-Plan tab indexes do not trigger maybeSyncIfStale', () {
    final apps = _SpyApps(client: _api(MockClient((_) async => http.Response('{}', 200))));

    // Home, Chat, Library, Apps. Anything that isn't Plan must NOT fire.
    maybeFireJiraRefreshOnTabSwitch(apps, 0);
    maybeFireJiraRefreshOnTabSwitch(apps, 1);
    maybeFireJiraRefreshOnTabSwitch(apps, 2);
    maybeFireJiraRefreshOnTabSwitch(apps, 4);

    expect(apps.calls, isEmpty);
  });

  test('Plan tab index triggers maybeSyncIfStale with the nooto-jira id and 60s window', () {
    final apps = _SpyApps(client: _api(MockClient((_) async => http.Response('{}', 200))));

    maybeFireJiraRefreshOnTabSwitch(apps, kPlanTabIndex);

    expect(apps.calls, hasLength(1));
    expect(apps.calls.single.appId, 'nooto-jira');
    expect(apps.calls.single.minAge, const Duration(seconds: 60));
  });

  test('REGRESSION (Issue 2.5): Plan -> Home -> Plan must fire maybeSyncIfStale BOTH times. '
      'If a future implementer moves the hook into PlanScreen.initState, this fails — '
      'IndexedStack constructs each child once per shell lifetime, so initState '
      'never re-runs on subsequent tab visits.', () {
    final apps = _SpyApps(client: _api(MockClient((_) async => http.Response('{}', 200))));

    maybeFireJiraRefreshOnTabSwitch(apps, kPlanTabIndex); // first Plan visit
    maybeFireJiraRefreshOnTabSwitch(apps, 0); // user pops to Home
    maybeFireJiraRefreshOnTabSwitch(apps, kPlanTabIndex); // back to Plan

    // The provider's own staleness gate may turn the second call into a
    // no-op against the network — that is the right behavior and is
    // covered separately. Here we are proving the HOOK runs on every
    // Plan visit, not just the first.
    expect(
      apps.calls.where((c) => c.appId == 'nooto-jira'),
      hasLength(2),
      reason: 'Hook must fire every time the user returns to the Plan tab.',
    );
  });
}
