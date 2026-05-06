import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:nooto_v2/services/chat_service.dart';

/// Status of the plan-guidance fetch — drives the voice card render in
/// `PlanScreen`. The card is intentionally tolerant of all four states:
/// `idle` and `loading` render nothing (the existing list shows beneath),
/// `ready` shows the assistant copy, `error` falls back to the bare list.
enum PlanGuidanceStatus { idle, loading, ready, error }

/// Holds the latest plan-guidance text + a content-keyed cache so opening
/// and closing the Plan tab doesn't refetch on every mount. Cached entries
/// live for [_cacheTtl] OR until the today-context shape materially changes
/// (different items, different counts).
class PlanGuidanceProvider extends ChangeNotifier {
  PlanGuidanceProvider({required ChatService service}) : _service = service;

  final ChatService _service;

  static const Duration _cacheTtl = Duration(minutes: 30);

  String _text = '';
  PlanGuidanceStatus _status = PlanGuidanceStatus.idle;
  String? _cacheKey;
  DateTime? _cachedAt;

  String get text => _text;
  PlanGuidanceStatus get status => _status;

  /// Idempotent fetch: hits the backend only when the cache is stale OR
  /// `todayContext` has changed since the last successful render. Safe to
  /// call from `initState` / `didChangeDependencies` repeatedly.
  Future<void> refreshIfStale(Map<String, dynamic> todayContext) async {
    final key = _hashContext(todayContext);
    final cached = _cacheKey;
    final cachedAt = _cachedAt;
    final isFresh = cached == key && cachedAt != null && DateTime.now().difference(cachedAt) < _cacheTtl;
    if (isFresh && _status == PlanGuidanceStatus.ready) return;
    if (_status == PlanGuidanceStatus.loading) return;

    _status = PlanGuidanceStatus.loading;
    notifyListeners();

    try {
      final body = await _service.fetchPlanGuidance(
        todayContext: todayContext,
        now: DateTime.now(),
      );
      _text = body.trim();
      _status = _text.isEmpty ? PlanGuidanceStatus.idle : PlanGuidanceStatus.ready;
      _cacheKey = key;
      _cachedAt = DateTime.now();
    } catch (_) {
      _status = PlanGuidanceStatus.error;
    }
    notifyListeners();
  }

  /// Drop the cache (e.g., on logout). Does not fire the next fetch.
  void clear() {
    _text = '';
    _status = PlanGuidanceStatus.idle;
    _cacheKey = null;
    _cachedAt = null;
    notifyListeners();
  }

  /// Stable hash over the parts of today_context the LLM grounds against.
  /// Counts + ids only — `due_at` and `age_in_days` change every minute and
  /// would otherwise invalidate the cache constantly.
  String _hashContext(Map<String, dynamic> ctx) {
    final overdue = (ctx['overdue'] as List? ?? []).map((e) => (e as Map)['id']).toList();
    final dueSoon = (ctx['due_soon'] as List? ?? []).map((e) => (e as Map)['id']).toList();
    final stuck = (ctx['stuck_jira'] as List? ?? []).map((e) => (e as Map)['id']).toList();
    final remaining = ctx['plan_remaining_count'];
    final canonical = jsonEncode({
      'overdue': overdue,
      'due_soon': dueSoon,
      'stuck': stuck,
      'remaining': remaining,
    });
    return md5.convert(utf8.encode(canonical)).toString();
  }
}
