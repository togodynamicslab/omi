import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:nooto_v2/inbox/inbox_message.dart';
import 'package:nooto_v2/services/api_client.dart';

/// Backs the InboxScreen. Fetches `/v2/chat/inbox/feed`, paginates by
/// `created_at` cursor, and exposes a client-side per-app filter.
///
/// Server-of-record: the messages live in Firestore, surfaced via the inbox
/// feed endpoint. v0 deliberately bypasses Hive — it's a thin live view, see
/// the design doc's "Inbox bypasses Hive for v0" note.
class InboxProvider extends ChangeNotifier {
  InboxProvider({required ApiClient client, int pageSize = 50}) : _client = client, _pageSize = pageSize;

  final ApiClient _client;
  final int _pageSize;

  final List<InboxMessage> _messages = [];
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  String? _nextCursor;
  bool _hasMore = true;
  String? _selectedAppId;
  bool _disposed = false;

  List<InboxMessage> get messages => List.unmodifiable(_messages);

  /// Client-side filtered view. Tapping a per-app chip or the sender meta
  /// line on a row sets `selectedAppId`; "All" clears it.
  List<InboxMessage> get messagesFiltered {
    final filter = _selectedAppId;
    if (filter == null) return messages;
    return _messages.where((m) => m.appId == filter).toList(growable: false);
  }

  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  String? get error => _error;
  String? get selectedAppId => _selectedAppId;
  bool get hasMore => _hasMore;

  /// Returns the distinct senders observed on the loaded page, ordered by
  /// most-recent-message-time desc. Used by the header chip row. Brief is
  /// modeled as a synthetic sender with `appId == null` and `type='brief'`.
  List<InboxChipSender> get chipSenders {
    final byKey = <String, InboxChipSender>{};
    for (final m in _messages) {
      final key = m.appId ?? '__brief__';
      final existing = byKey[key];
      if (existing == null || m.createdAt.isAfter(existing.lastMessageAt)) {
        byKey[key] = InboxChipSender(
          appId: m.appId,
          displayName: m.sender.displayName,
          avatarUrl: m.sender.avatarUrl,
          type: m.sender.type,
          lastMessageAt: m.createdAt,
        );
      }
    }
    final list = byKey.values.toList()..sort((a, b) => b.lastMessageAt.compareTo(a.lastMessageAt));
    return list;
  }

  void setFilter(String? appId) {
    if (_selectedAppId == appId) return;
    _selectedAppId = appId;
    _safeNotify();
  }

  void clearFilter() => setFilter(null);

  /// First load + pull-to-refresh. Resets the cursor and replaces the list.
  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    _error = null;
    _safeNotify();
    try {
      final page = await _fetchPage(before: null);
      _messages
        ..clear()
        ..addAll(page.items);
      _nextCursor = page.nextCursor;
      _hasMore = page.nextCursor != null;
    } on ApiError catch (e, stack) {
      _error = 'HTTP ${e.statusCode}';
      debugPrint('[InboxProvider] refresh ApiError: $e\n$stack');
    } catch (e, stack) {
      _error = e.toString();
      debugPrint('[InboxProvider] refresh error: $e\n$stack');
    } finally {
      _loading = false;
      _safeNotify();
    }
  }

  /// Triggered when the list scrolls past 80%. No-op while another fetch is
  /// in flight or no more pages are available.
  Future<void> loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final cursor = _nextCursor;
    if (cursor == null) return;
    _loadingMore = true;
    _safeNotify();
    try {
      final page = await _fetchPage(before: cursor);
      _messages.addAll(page.items);
      _nextCursor = page.nextCursor;
      _hasMore = page.nextCursor != null;
    } on ApiError {
      // Soft-fail pagination: keep what we have, surface error on next refresh.
      _hasMore = false;
    } catch (_) {
      _hasMore = false;
    } finally {
      _loadingMore = false;
      _safeNotify();
    }
  }

  Future<_FeedPage> _fetchPage({String? before}) async {
    final qp = <String, String>{'limit': '$_pageSize'};
    if (before != null) qp['before'] = before;
    final query = qp.entries
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final response = await _client.get('v2/chat/inbox/feed?$query');
    final decoded = jsonDecode(response.body);
    final items = <InboxMessage>[];
    String? nextCursor;
    if (decoded is Map<String, dynamic>) {
      final raw = decoded['items'];
      if (raw is List) {
        for (final entry in raw) {
          if (entry is Map<String, dynamic>) {
            items.add(InboxMessage.fromJson(entry));
          }
        }
      }
      final cursor = decoded['next_cursor'];
      if (cursor is String && cursor.isNotEmpty) nextCursor = cursor;
    }
    return _FeedPage(items: items, nextCursor: nextCursor);
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _FeedPage {
  _FeedPage({required this.items, required this.nextCursor});
  final List<InboxMessage> items;
  final String? nextCursor;
}

/// Lightweight projection of a sender for the chip row. Brief is modeled with
/// `appId == null`.
class InboxChipSender {
  const InboxChipSender({
    required this.appId,
    required this.displayName,
    required this.avatarUrl,
    required this.type,
    required this.lastMessageAt,
  });

  final String? appId;
  final String displayName;
  final String? avatarUrl;
  final String type;
  final DateTime lastMessageAt;

  bool get isBrief => type == 'day_summary' || type == 'brief';
}
