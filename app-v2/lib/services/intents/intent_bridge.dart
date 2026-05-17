import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:nooto_v2/services/api_client.dart';
import 'package:nooto_v2/services/intents/cloud_intent_parser.dart';
import 'package:nooto_v2/services/intents/intent_dispatcher.dart';
import 'package:nooto_v2/services/intents/intent_models.dart';

/// Orchestrator for the on-device intent dispatcher feature.
///
/// Picks the parser at runtime:
///   - **Native LLM** (`com.nooto.intent_bridge`, iOS 26+ with Apple
///     Intelligence) — Foundation Models in-process, ~500ms-2s,
///     fully offline.
///   - **Cloud LLM** (existing `ChatService` /v2/messages backend) —
///     used when the native bridge reports unavailable. Same intent schema.
///
/// Dispatch always goes through `IntentDispatcher` (the
/// `com.nooto.intent_dispatcher` channel) so the EventKit write happens
/// natively regardless of which parser produced the structured intent.
///
/// Per the design doc at
/// `~/.gstack/projects/togodynamicslab-omi/matheusoliviera-main-design-poc-on-device-intent-*.md`.
class IntentBridge {
  IntentBridge({ApiClient? apiClient})
      : _cloudParser = apiClient != null ? CloudIntentParser(apiClient: apiClient) : null;

  static const MethodChannel _channel = MethodChannel('com.nooto.intent_bridge');

  /// Optional. When provided (with an ApiClient), allows the cloud-fallback
  /// path via the dedicated `/v2/intents/parse` endpoint. Null means
  /// native-only (cloud unreachable / not wired in main.dart).
  final CloudIntentParser? _cloudParser;
  final IntentDispatcher _dispatcher = IntentDispatcher();

  /// Whether the on-device LLM bridge is reachable. Cloud is treated as
  /// available whenever a `ChatService` was injected — we don't ping the
  /// backend up-front.
  Future<IntentAvailability> checkAvailability() async {
    if (!_isSupportedPlatform) {
      return const IntentAvailability(
        available: false,
        reason: 'On-device intent parsing is currently iOS-only.',
      );
    }
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('checkAvailability');
      if (result == null) {
        return const IntentAvailability(available: false, reason: 'native returned no payload');
      }
      return IntentAvailability.fromWire(result);
    } on PlatformException catch (e) {
      debugPrint('[IntentBridge] checkAvailability failed: $e');
      return IntentAvailability(available: false, reason: e.message);
    } on MissingPluginException {
      // No native LLM bridge — iOS < 26, or simulator without Apple Intelligence.
      // Cloud parser may still work.
      return const IntentAvailability(
        available: false,
        reason: 'On-device LLM not available — using cloud fallback if configured.',
      );
    }
  }

  /// Run a single parse-and-dispatch round.
  /// Strategy:
  ///   1. Try the native LLM. If it returns a non-unknown intent → done.
  ///   2. Otherwise, fall back to the cloud parser (if configured) and
  ///      dispatch via the structured dispatcher.
  ///   3. If both miss, return Unknown.
  /// Never throws.
  Future<IntentResult> parseAndDispatch(String text) async {
    // ---- Try the native LLM bridge first ----
    final nativeResult = await _tryNative(text);
    if (nativeResult != null && nativeResult.intentKind != IntentKind.unknown) {
      return nativeResult;
    }
    // ---- Cloud fallback ----
    if (_cloudParser != null) {
      final cloudResult = await _tryCloud(text);
      if (cloudResult != null) return cloudResult;
    }
    // ---- Total miss ----
    final nativeReason = nativeResult?.failureReason ?? 'on-device parse unavailable';
    return IntentResult(
      parsedJson: '{"kind": "unknown", "reason": "no parser available"}',
      intentKind: IntentKind.unknown,
      status: DispatchStatus.noop,
      failureReason: nativeReason,
      latencyMs: nativeResult?.latencyMs ?? 0,
      blockedBySafetyClassifier: nativeResult?.blockedBySafetyClassifier ?? false,
    );
  }

  Future<IntentResult?> _tryNative(String text) async {
    if (!_isSupportedPlatform) return null;
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'parseAndDispatch',
        {'text': text},
      );
      if (result == null) return null;
      return IntentResult.fromWire(result);
    } on PlatformException catch (e) {
      debugPrint('[IntentBridge] native parseAndDispatch failed: $e');
      return null;
    } on MissingPluginException {
      // Native bridge not registered (iOS < 26). Caller will try cloud.
      return null;
    }
  }

  Future<IntentResult?> _tryCloud(String text) async {
    final parser = _cloudParser;
    if (parser == null) return null;
    final stopwatch = Stopwatch()..start();
    final result = await parser.parse(text);
    final latencyMs = stopwatch.elapsedMilliseconds;

    if (!result.ok) {
      // Parse failed (backend unreachable, non-JSON response, etc.).
      // Return a structured failure so chat_provider can surface the
      // reason instead of falling back to vanilla chat (which would
      // produce a generic "Sorry, I encountered an error").
      return IntentResult(
        parsedJson: '{"kind": "unknown", "reason": "cloud parser failed"}',
        intentKind: IntentKind.unknown,
        status: DispatchStatus.failed,
        failureReason: result.failureReason ?? 'cloud parser failed',
        latencyMs: latencyMs,
        blockedBySafetyClassifier: false,
      );
    }

    final draft = result.draft!;
    final kindRaw = (draft['kind'] as String?) ?? 'unknown';
    final kind = IntentKind.fromWire(kindRaw);

    if (kind == IntentKind.unknown) {
      return IntentResult(
        parsedJson: _prettyJson(draft),
        intentKind: IntentKind.unknown,
        status: DispatchStatus.noop,
        failureReason: (draft['reason'] as String?) ?? 'cloud parser returned unknown',
        latencyMs: latencyMs,
        blockedBySafetyClassifier: false,
      );
    }

    // Dispatch via the dispatcher bridge.
    final outcome = await _dispatcher.dispatchStructured(
      kind: kindRaw,
      time: draft['time'] as String?,
      seconds: draft['seconds'] as int?,
      recurrence: draft['recurrence'] as String?,
      label: draft['label'] as String?,
      title: draft['title'] as String?,
      start: draft['start'] as String?,
      durationMinutes: draft['durationMinutes'] as int?,
      due: draft['due'] as String?,
      location: draft['location'] as String?,
      notes: draft['notes'] as String?,
    );
    return IntentResult(
      parsedJson: _prettyJson(draft),
      intentKind: kind,
      status: outcome.status,
      failureReason: outcome.reason,
      latencyMs: latencyMs,
      blockedBySafetyClassifier: false,
    );
  }

  String _prettyJson(Map<String, dynamic> map) {
    try {
      return const JsonEncoder.withIndent('  ').convert(map);
    } catch (_) {
      return map.toString();
    }
  }

  bool get _isSupportedPlatform {
    if (kIsWeb) return false;
    return Platform.isIOS;
  }
}
