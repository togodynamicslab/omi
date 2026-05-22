import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nooto_v2/services/auth_service.dart';

/// Fetches the morning brief from the Nooto v2 agent backend.
///
/// Separate from `ApiClient` because the agent endpoint lives on the new
/// nooto-v2 backend (not the legacy Omi backend ApiClient targets). The URL
/// is `--dart-define` configurable so ngrok URLs and Coolify deploys can
/// both be plugged in without code changes.
///
/// Wire contract (POST /v1/agent/run/morning-brief):
///   Request body:
///     {
///       "context": {
///         "user": {"display_name": "..."},
///         "last_brief_at": "`<ISO 8601>`" | "never"
///       }
///     }
///   Response (200):
///     {
///       "output": "`<brief text>`",
///       "iterations": int,
///       "tool_calls": [...],
///       "input_tokens": int,
///       "output_tokens": int,
///       "cache_read_tokens": int,
///       "stop_reason": str
///     }
class BriefService {
  BriefService({http.Client? httpClient, SharedPreferences? prefs})
    : _http = httpClient ?? http.Client(),
      _prefsOverride = prefs;

  /// Backend URL for the brief agent endpoint. Defaults to the dev's reserved
  /// ngrok tunnel; override via `--dart-define=NOOTO_BACKEND_URL=...` to point
  /// at a Coolify deploy or a different ngrok URL.
  static const String backendUrl = String.fromEnvironment(
    'NOOTO_BACKEND_URL',
    defaultValue: 'https://td.ngrok.app',
  );

  /// SharedPreferences key for the last successful brief timestamp (ISO 8601).
  static const String _lastBriefAtKey = 'nooto_v2.brief.last_at';

  final http.Client _http;
  final SharedPreferences? _prefsOverride;

  Future<SharedPreferences> _prefs() async {
    return _prefsOverride ?? await SharedPreferences.getInstance();
  }

  /// Fetches a fresh morning brief. Throws [BriefException] on auth, network,
  /// or non-200 responses.
  Future<Brief> fetchMorningBrief({
    required String displayName,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final token = await AuthService.instance.getIdToken();
    if (token == null || token.isEmpty) {
      throw const BriefException('Not signed in — no Firebase ID token available.');
    }

    final lastBriefAt = await _readLastBriefAt();
    final uri = Uri.parse('$backendUrl/v1/agent/run/morning-brief');

    http.Response response;
    try {
      response = await _http
          .post(
            uri,
            headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
            body: jsonEncode({
              'context': {
                'user': {'display_name': displayName},
                'last_brief_at': lastBriefAt,
              },
            }),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const BriefException('Brief request timed out.');
    } catch (e) {
      throw BriefException('Brief request failed: $e');
    }

    if (response.statusCode != 200) {
      final preview = response.body.length > 200 ? '${response.body.substring(0, 200)}…' : response.body;
      throw BriefException('HTTP ${response.statusCode}: $preview');
    }

    final Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const BriefException('Brief response was not a JSON object.');
      }
      data = decoded;
    } on FormatException catch (e) {
      throw BriefException('Brief response was not valid JSON: $e');
    }

    final output = data['output'];
    if (output is! String || output.trim().isEmpty) {
      throw const BriefException('Brief response had no output text.');
    }

    final synthesizedAt = DateTime.now();
    await _writeLastBriefAt(synthesizedAt);

    return Brief(
      text: output.trim(),
      synthesizedAt: synthesizedAt,
      iterations: _readInt(data['iterations']),
      inputTokens: _readInt(data['input_tokens']),
      outputTokens: _readInt(data['output_tokens']),
      cacheReadTokens: _readInt(data['cache_read_tokens']),
    );
  }

  /// Returns the ISO 8601 timestamp of the last successful brief fetch, or
  /// the sentinel `"never"` if none has been recorded.
  Future<String> _readLastBriefAt() async {
    final prefs = await _prefs();
    return prefs.getString(_lastBriefAtKey) ?? 'never';
  }

  Future<void> _writeLastBriefAt(DateTime when) async {
    final prefs = await _prefs();
    await prefs.setString(_lastBriefAtKey, when.toUtc().toIso8601String());
  }

  static int _readInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return 0;
  }
}

/// Typed brief response payload.
@immutable
class Brief {
  const Brief({
    required this.text,
    required this.synthesizedAt,
    required this.iterations,
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
  });

  final String text;
  final DateTime synthesizedAt;
  final int iterations;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
}

/// Raised by [BriefService] on any failure path (auth, network, parsing,
/// non-2xx). Carries a single human-readable summary; callers should log
/// and surface a muted "Couldn't reach Nooto" line on the brief card.
class BriefException implements Exception {
  const BriefException(this.message);
  final String message;

  @override
  String toString() => 'BriefException: $message';
}
