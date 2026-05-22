import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nooto_v2/services/auth_service.dart';

/// Fetches the email-triage report from the Nooto v2 agent backend.
///
/// Sibling of [BriefService]. Same wire shape, different endpoint. The agent
/// returns a short multi-paragraph report:
///   - anchor sentence (≤1 sentence, urgent reply or "Inbox clear …")
///   - bucket counts line ("N needs-reply · M FYI · K noise.")
///   - itemized email lines
///   - optional FYI lines
/// Card rendering treats the first paragraph (split on the first `\n\n`) as
/// the greeting line and the remainder as body. No further client-side
/// formatting — the agent already wrote the speech.
///
/// Wire contract (POST /v1/agent/run/email-triage):
///   Request body:
///     {
///       "context": {
///         "user": {"display_name": "..."},
///         "since": "`<ISO 8601>`" | "never"
///       }
///     }
///   Response (200):
///     {
///       "output": "`<triage text>`",
///       "iterations": int,
///       "tool_calls": [...],
///       "input_tokens": int,
///       "output_tokens": int,
///       "cache_read_tokens": int,
///       "stop_reason": str
///     }
class EmailTriageService {
  EmailTriageService({http.Client? httpClient, SharedPreferences? prefs})
    : _http = httpClient ?? http.Client(),
      _prefsOverride = prefs;

  /// Backend URL for the triage agent endpoint. Same `--dart-define` knob as
  /// [BriefService.backendUrl] — one switch flips both surfaces between local
  /// ngrok and a Coolify deploy.
  static const String backendUrl = String.fromEnvironment('NOOTO_BACKEND_URL', defaultValue: 'https://td.ngrok.app');

  /// SharedPreferences key for the last successful triage timestamp (ISO 8601).
  /// Mirrors `nooto_v2.brief.last_at`.
  static const String _lastTriageAtKey = 'nooto_v2.triage.last_at';

  final http.Client _http;
  final SharedPreferences? _prefsOverride;

  Future<SharedPreferences> _prefs() async {
    return _prefsOverride ?? await SharedPreferences.getInstance();
  }

  /// Fetches a fresh triage report. Throws [EmailTriageException] on auth,
  /// network, or non-200 responses.
  Future<EmailTriageResult> fetchEmailTriage({
    required String displayName,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final token = await AuthService.instance.getIdToken();
    if (token == null || token.isEmpty) {
      throw const EmailTriageException('Not signed in — no Firebase ID token available.');
    }

    final since = await _readLastTriageAt();
    final uri = Uri.parse('$backendUrl/v1/agent/run/email-triage');

    http.Response response;
    try {
      response = await _http
          .post(
            uri,
            headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
            body: jsonEncode({
              'context': {
                'user': {'display_name': displayName},
                'since': since,
              },
            }),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const EmailTriageException('Triage request timed out.');
    } catch (e) {
      throw EmailTriageException('Triage request failed: $e');
    }

    if (response.statusCode != 200) {
      final preview = response.body.length > 200 ? '${response.body.substring(0, 200)}…' : response.body;
      throw EmailTriageException('HTTP ${response.statusCode}: $preview');
    }

    final Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const EmailTriageException('Triage response was not a JSON object.');
      }
      data = decoded;
    } on FormatException catch (e) {
      throw EmailTriageException('Triage response was not valid JSON: $e');
    }

    final output = data['output'];
    if (output is! String || output.trim().isEmpty) {
      throw const EmailTriageException('Triage response had no output text.');
    }

    final synthesizedAt = DateTime.now();
    await _writeLastTriageAt(synthesizedAt);

    return EmailTriageResult(
      text: output.trim(),
      synthesizedAt: synthesizedAt,
      iterations: _readInt(data['iterations']),
      inputTokens: _readInt(data['input_tokens']),
      outputTokens: _readInt(data['output_tokens']),
      cacheReadTokens: _readInt(data['cache_read_tokens']),
    );
  }

  /// Returns the ISO 8601 timestamp of the last successful triage fetch, or
  /// the sentinel `"never"` if none has been recorded.
  Future<String> _readLastTriageAt() async {
    final prefs = await _prefs();
    return prefs.getString(_lastTriageAtKey) ?? 'never';
  }

  Future<void> _writeLastTriageAt(DateTime when) async {
    final prefs = await _prefs();
    await prefs.setString(_lastTriageAtKey, when.toUtc().toIso8601String());
  }

  static int _readInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return 0;
  }
}

/// Typed triage response payload.
@immutable
class EmailTriageResult {
  const EmailTriageResult({
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

/// Raised by [EmailTriageService] on any failure path (auth, network, parsing,
/// non-2xx). Carries a single human-readable summary; callers should log and
/// surface a muted "Couldn't reach Nooto" line on the triage card.
class EmailTriageException implements Exception {
  const EmailTriageException(this.message);
  final String message;

  @override
  String toString() => 'EmailTriageException: $message';
}
