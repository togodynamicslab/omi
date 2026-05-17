import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:nooto_v2/apps/jira_status_classification.dart';
import 'package:nooto_v2/services/api_client.dart';

/// Owns the Jira status-classifications list shown in the "Statuses" sub-page
/// of the Jira app detail screen.
///
/// Read side: `GET /v1/integrations/jira/status-classifications` returns
/// every (cloudid, status_name) the user's tickets have ever touched, with
/// the current bucket (self / waiting / blocked / completed / dropped / null).
/// Write side: `POST /v1/integrations/jira/status-classifications/override`
/// flips one row's bucket and triggers a backend re-fan-out across the
/// matching items.
///
/// Optimistic update on [override]: the matching row's bucket and source flip
/// immediately; on POST failure the row is rolled back to the pre-call snapshot
/// and [error] is set so the screen can surface a snackbar.
class JiraStatusesProvider extends ChangeNotifier {
  JiraStatusesProvider({required ApiClient client}) : _client = client;

  final ApiClient _client;

  static const String _listPath = 'v1/integrations/jira/status-classifications';
  static const String _overridePath = 'v1/integrations/jira/status-classifications/override';

  /// Allowed override bucket values. Kept here (not in the model) so the UI
  /// picker and the provider's validation use the same source of truth.
  static const List<String> allowedBuckets = ['self', 'waiting', 'blocked', 'completed', 'dropped'];

  List<JiraStatusClassification> _items = const [];
  bool _loading = false;
  String? _error;

  List<JiraStatusClassification> get items => _items;
  bool get loading => _loading;
  String? get error => _error;

  /// Fetches the full list and sorts by [JiraStatusClassification.matchingItemCount]
  /// descending so high-impact statuses surface first. Safe to call on every
  /// screen entry — the screen owns its own pull-to-refresh.
  Future<void> fetchAll() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final res = await _client.get(_listPath);
      final decoded = jsonDecode(res.body);
      final raw = decoded is Map ? decoded['items'] : null;
      final parsed = raw is List
          ? raw.whereType<Map>().map((m) => JiraStatusClassification.fromJson(Map<String, dynamic>.from(m))).toList()
          : <JiraStatusClassification>[];
      parsed.sort((a, b) => b.matchingItemCount.compareTo(a.matchingItemCount));
      _items = parsed;
    } catch (e, st) {
      debugPrint('[JiraStatusesProvider] fetchAll failed: $e\n$st');
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Override one (cloudid, status_name) → bucket. Optimistic: flips the
  /// matching row immediately (source becomes "override"), POSTs to backend,
  /// rolls back on failure.
  ///
  /// Returns the `items_updated` count on success, or null on failure. The
  /// UI uses the count to render the "Updated N items" snackbar.
  Future<int?> override({required String cloudid, required String statusName, required String bucket}) async {
    if (!allowedBuckets.contains(bucket)) {
      _error = 'Invalid bucket: $bucket';
      notifyListeners();
      return null;
    }
    // Snapshot for rollback. Index lookup is cheap (lists here are small —
    // tens of statuses, not thousands) and the match-by-cloudid+name keeps
    // the rollback exact even if the list was re-sorted between calls.
    final snapshot = List<JiraStatusClassification>.from(_items);
    final idx = _items.indexWhere((i) => i.cloudid == cloudid && i.statusName == statusName);
    if (idx >= 0) {
      final updated = _items[idx].copyWith(bucket: bucket, source: 'override');
      final next = List<JiraStatusClassification>.from(_items);
      next[idx] = updated;
      _items = next;
      notifyListeners();
    }
    try {
      final res = await _client.post(
        _overridePath,
        body: {'cloudid': cloudid, 'status_name': statusName, 'bucket': bucket},
      );
      final body = jsonDecode(res.body);
      final count = body is Map ? body['items_updated'] : null;
      if (count is int) return count;
      if (count is num) return count.toInt();
      return 0;
    } catch (e) {
      debugPrint('[JiraStatusesProvider] override failed: $e');
      _items = snapshot;
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }
}
