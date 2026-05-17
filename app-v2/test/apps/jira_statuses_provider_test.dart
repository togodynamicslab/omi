import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:nooto_v2/apps/jira_statuses_provider.dart';
import 'package:nooto_v2/services/api_client.dart';

ApiClient _api(MockClient mock) => ApiClient(
  httpClient: mock,
  getIdToken: ({bool forceRefresh = false}) async => 'tok',
  signOut: () async {},
  baseUrl: 'https://example.test/',
);

Map<String, dynamic> _row({
  String cloudid = 'cloud-1',
  String statusName = 'In Progress',
  String? bucket = 'self',
  String? source = 'llm',
  String? certainty = 'high',
  int count = 3,
}) => {
  'cloudid': cloudid,
  'status_name': statusName,
  'status_category': 'In Progress',
  'bucket': bucket,
  'actionability': null,
  'resolution': null,
  'source': source,
  'certainty': certainty,
  'classified_at': '2026-05-17T12:00:00Z',
  'matching_item_count': count,
};

void main() {
  group('JiraStatusesProvider.fetchAll', () {
    test('hydrates items sorted by matching_item_count desc on success', () async {
      final mock = MockClient((req) async {
        expect(req.url.path, '/v1/integrations/jira/status-classifications');
        expect(req.method, 'GET');
        return http.Response(
          jsonEncode({
            'items': [
              _row(statusName: 'Low', count: 1),
              _row(statusName: 'High', count: 10),
              _row(statusName: 'Mid', count: 5),
            ],
          }),
          200,
        );
      });
      final provider = JiraStatusesProvider(client: _api(mock));

      await provider.fetchAll();

      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
      expect(provider.items, hasLength(3));
      // High-count first — the sort is what drives "show me the statuses that
      // affect the most tickets" UX.
      expect(provider.items[0].statusName, 'High');
      expect(provider.items[1].statusName, 'Mid');
      expect(provider.items[2].statusName, 'Low');
    });

    test('captures error and leaves items empty on 500', () async {
      final mock = MockClient((_) async => http.Response('boom', 500));
      final provider = JiraStatusesProvider(client: _api(mock));

      await provider.fetchAll();

      expect(provider.error, isNotNull);
      expect(provider.items, isEmpty);
      expect(provider.loading, isFalse);
    });

    test('handles malformed body without crashing', () async {
      final mock = MockClient((_) async => http.Response('"not a map"', 200));
      final provider = JiraStatusesProvider(client: _api(mock));

      await provider.fetchAll();

      expect(provider.items, isEmpty);
      expect(provider.error, isNull);
    });
  });

  group('JiraStatusesProvider.override', () {
    test('POSTs the right body, optimistically updates, returns items_updated', () async {
      Map<String, dynamic>? capturedBody;
      var calls = 0;
      final mock = MockClient((req) async {
        if (req.method == 'GET') {
          return http.Response(
            jsonEncode({
              'items': [_row(statusName: 'Code Review', bucket: 'self', source: 'llm')],
            }),
            200,
          );
        }
        // POST path.
        calls += 1;
        expect(req.url.path, '/v1/integrations/jira/status-classifications/override');
        capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'redis_written': true, 'items_updated': 4, 'bucket': 'waiting'}), 200);
      });
      final provider = JiraStatusesProvider(client: _api(mock));
      await provider.fetchAll();
      expect(provider.items.single.bucket, 'self');
      expect(provider.items.single.source, 'llm');

      final updated = await provider.override(cloudid: 'cloud-1', statusName: 'Code Review', bucket: 'waiting');

      expect(calls, 1);
      expect(updated, 4);
      expect(capturedBody, {'cloudid': 'cloud-1', 'status_name': 'Code Review', 'bucket': 'waiting'});
      // Optimistic update stayed in place after success — bucket flipped and
      // source flipped to override so the row subtitle reflects user intent.
      expect(provider.items.single.bucket, 'waiting');
      expect(provider.items.single.source, 'override');
      expect(provider.error, isNull);
    });

    test('rolls back optimistic update and sets error on POST failure', () async {
      final mock = MockClient((req) async {
        if (req.method == 'GET') {
          return http.Response(
            jsonEncode({
              'items': [_row(statusName: 'Awaiting QA', bucket: 'self', source: 'llm')],
            }),
            200,
          );
        }
        return http.Response('{"detail":"boom"}', 500);
      });
      final provider = JiraStatusesProvider(client: _api(mock));
      await provider.fetchAll();
      expect(provider.items.single.bucket, 'self');

      final updated = await provider.override(cloudid: 'cloud-1', statusName: 'Awaiting QA', bucket: 'waiting');

      expect(updated, isNull);
      // Rolled back to the pre-call snapshot — source and bucket unchanged.
      expect(provider.items.single.bucket, 'self');
      expect(provider.items.single.source, 'llm');
      expect(provider.error, isNotNull);
    });

    test('rejects an invalid bucket without hitting the network', () async {
      var calls = 0;
      final mock = MockClient((_) async {
        calls += 1;
        return http.Response('{}', 200);
      });
      final provider = JiraStatusesProvider(client: _api(mock));

      final updated = await provider.override(cloudid: 'c', statusName: 's', bucket: 'nonsense');

      expect(updated, isNull);
      expect(calls, 0);
      expect(provider.error, contains('Invalid bucket'));
    });
  });
}
