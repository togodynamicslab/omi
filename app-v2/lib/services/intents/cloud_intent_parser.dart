import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:nooto_v2/services/api_client.dart';

/// Tagged-union result from `CloudIntentParser.parse`. Lets the orchestrator
/// distinguish "parse succeeded with intent fields" from "tried but failed
/// — here's why" so the failure can be surfaced in the chat rather than
/// silently retried as a regular chat message.
class CloudParseResult {
  final Map<String, dynamic>? draft;
  final String? failureReason;

  bool get ok => draft != null;

  const CloudParseResult.success(Map<String, dynamic> draft)
      : draft = draft,
        failureReason = null;

  const CloudParseResult.failure(String reason)
      : draft = null,
        failureReason = reason;
}

/// Cloud fallback for the intent parser. Used when Apple Foundation Models
/// isn't available on the device (iOS 18, non-Apple-Intelligence hardware).
///
/// Calls the dedicated `/v2/intents/parse` backend endpoint
/// (`backend/routers/intents.py`). That endpoint uses gpt-4.1-mini with
/// `response_format=json_object` for structured extraction — strictly
/// cheaper and faster than the conversational `/v2/messages` agent path
/// (~20-40× cheaper per call, no Jira tool schemas loaded).
class CloudIntentParser {
  CloudIntentParser({required ApiClient apiClient}) : _client = apiClient;

  final ApiClient _client;

  /// Parse [text] into a structured intent map matching the native bridge's
  /// `LLMIntentDraft` schema:
  ///   { kind, time?, recurrence?, seconds?, title?, start?, due?, location?,
  ///     notes?, label?, reason? }
  Future<CloudParseResult> parse(String text) async {
    final now = DateTime.now();
    final body = {
      'text': text,
      'now_iso': now.toIso8601String(),
      'now_weekday': _weekdayName(now.weekday),
    };

    try {
      final response = await _client.post('v2/intents/parse', body: body);
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return CloudParseResult.failure('backend returned non-object JSON');
      }
      return CloudParseResult.success(decoded);
    } catch (e) {
      debugPrint('[CloudIntentParser] /v2/intents/parse failed: $e');
      return CloudParseResult.failure('Intent endpoint failed: $e');
    }
  }

  String _weekdayName(int weekday) {
    const names = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return names[weekday - 1];
  }
}
