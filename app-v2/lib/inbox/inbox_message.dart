/// Plain data model for one row in the inbox feed.
///
/// Mirrors the JSON shape returned by `GET /v2/chat/inbox/feed` (see
/// `backend/routers/chat.py:get_inbox_feed`):
/// `{ id, text, created_at, app_id, type, sender: { display_name, avatar_url, type } }`.
///
/// `type` on the sender distinguishes Brief (`day_summary`) from regular
/// app-authored messages (`app`); the screen uses [isBrief] to render the
/// sender name in `brandPrimary` for Brief rows. App rows always use
/// `textPrimary`.
class InboxMessage {
  const InboxMessage({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.appId,
    required this.sender,
  });

  final String id;
  final String text;
  final DateTime createdAt;

  /// Null on `type='day_summary'` Brief rows. Set on app/integration rows.
  final String? appId;

  final InboxSender sender;

  /// Brief day-summary rows render the sender name in brand blue. App rows
  /// stay neutral. Single source of truth so the screen + chip row + filter
  /// logic agree on what counts as "Brief".
  bool get isBrief => sender.type == 'day_summary' || sender.type == 'brief';

  factory InboxMessage.fromJson(Map<String, dynamic> json) {
    final senderJson = json['sender'];
    final sender = senderJson is Map<String, dynamic>
        ? InboxSender.fromJson(senderJson)
        : InboxSender.fallback((json['type'] is String) ? json['type'] as String : 'app');
    return InboxMessage(
      id: (json['id'] ?? '').toString(),
      text: (json['text'] ?? '').toString(),
      createdAt: _parseTimestamp(json['created_at']),
      appId: (json['app_id'] is String) ? json['app_id'] as String : null,
      sender: sender,
    );
  }

  static DateTime _parseTimestamp(Object? raw) {
    if (raw is String && raw.isNotEmpty) {
      try {
        // Backend returns ISO 8601 with timezone (or "Z" suffix).
        return DateTime.parse(raw).toLocal();
      } catch (_) {
        return DateTime.fromMillisecondsSinceEpoch(0);
      }
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}

/// Sender block resolved server-side. `avatar_url` may be null when the apps
/// registry returned no logo for the integration; the UI falls back to a
/// monogram circle.
class InboxSender {
  const InboxSender({required this.displayName, required this.avatarUrl, required this.type});

  final String displayName;
  final String? avatarUrl;

  /// `'app'`, `'brief'`, or `'day_summary'` (legacy). Used by [InboxMessage.isBrief].
  final String type;

  factory InboxSender.fromJson(Map<String, dynamic> json) {
    return InboxSender(
      displayName: (json['display_name'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] is String) ? json['avatar_url'] as String : null,
      type: (json['type'] ?? 'app').toString(),
    );
  }

  factory InboxSender.fallback(String type) {
    return InboxSender(displayName: '', avatarUrl: null, type: type);
  }
}
