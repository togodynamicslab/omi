import 'dart:async';
import 'dart:convert';

import 'package:nooto_v2/services/api_client.dart';

/// One frame from the chat-stream wire protocol after parsing.
///
/// Wire format from the backend (`chat.py:execute_chat_stream` +
/// `agentic.py:AsyncStreamingCallback`):
///   `data: <token>\n\n`           → [ChatStreamText]
///   `think: <label>` (optionally with `|app_id:<id>` suffix) → [ChatStreamToolStart]
///   `tool_result: <base64-json>`  → ignored for now (rich card payload)
///   `done: <base64-payload>`      → stream closes
///   `__CRLF__` is the literal chunked-safe newline encoding; we restore it.
sealed class ChatStreamEvent {
  const ChatStreamEvent();
}

class ChatStreamText extends ChatStreamEvent {
  const ChatStreamText(this.text);
  final String text;
}

class ChatStreamToolStart extends ChatStreamEvent {
  const ChatStreamToolStart(this.label);
  final String label;
}

/// Wraps `POST /v2/messages` for both the morning brief (one-shot accumulate)
/// and the chat tab (token-by-token streaming UI with tool-use indicators).
class ChatService {
  ChatService({required ApiClient client}) : _client = client;

  final ApiClient _client;

  /// Streams parsed events from the assistant. Emits text deltas and
  /// tool-use indicators as they arrive; closes on `done:`.
  ///
  /// Note: the backend's `app_id` query param expects a registered app id;
  /// sending an arbitrary string makes the chat pipeline error, so we call
  /// the bare endpoint. Tagging brief vs chat traffic on the server is a
  /// follow-up.
  ///
  /// [todayContext] is optional structured grounding for the morning brief —
  /// the backend renders it as a `<today_context>` system block. Chat-tab
  /// traffic passes null and the field is omitted from the wire body.
  Stream<ChatStreamEvent> streamChat(String prompt, {Map<String, dynamic>? todayContext}) async* {
    final stream = await _client.stream(
      'v2/messages',
      body: {
        'text': prompt,
        'file_ids': null,
        if (todayContext != null) 'today_context': todayContext,
      },
    );

    final controller = StreamController<ChatStreamEvent>();
    String pending = '';

    final sub = stream
        .transform(utf8.decoder)
        .listen(null, onError: controller.addError, cancelOnError: true);

    sub.onData((chunk) {
      pending += chunk;
      var idx = pending.indexOf('\n');
      while (idx != -1) {
        final line = pending.substring(0, idx);
        pending = pending.substring(idx + 1);
        final parsed = _parseLine(line);
        if (parsed is _Done) {
          controller.close();
          sub.cancel();
          return;
        }
        if (parsed is ChatStreamEvent) controller.add(parsed);
        idx = pending.indexOf('\n');
      }
    });

    sub.onDone(() {
      // Closed without an explicit `done:` — emit any pending tail and finish.
      if (pending.isNotEmpty) {
        final parsed = _parseLine(pending);
        if (parsed is ChatStreamEvent) controller.add(parsed);
      }
      controller.close();
    });

    yield* controller.stream;
  }

  /// One-shot variant for the morning brief: accumulates the full response
  /// text. Tool-use chips are dropped — the brief surface doesn't show them.
  /// Times out at [timeout] for the entire fetch — protects against backend
  /// stalls poisoning the 24h cache.
  ///
  /// [todayContext] is the structured grounding the brief LLM uses to emit
  /// inline chip refs (`<plan id="..."/>`, `<ticket id="..."/>`) by id. Shape:
  /// `{ overdue: [...], due_soon: [...], stuck_jira: [...], plan_remaining_count: N }`.
  /// When omitted, the brief is ungrounded (legacy behavior).
  Future<String> fetchBrief({
    required String prompt,
    Map<String, dynamic>? todayContext,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final buffer = StringBuffer();
    await for (final event in streamChat(prompt, todayContext: todayContext).timeout(timeout)) {
      if (event is ChatStreamText) buffer.write(event.text);
    }
    return buffer.toString();
  }

  /// One-shot fetch for the Plan tab guidance card. Hits
  /// `POST /v2/plan/guidance`, accumulates the text/event-stream response.
  /// Wire shape mirrors the brief (`data: <chunk>` lines), so the existing
  /// SSE parser handles it without special-casing.
  ///
  /// [todayContext] is the same shape the brief uses (overdue / due_soon /
  /// stuck_jira / plan_remaining_count) — built once on the Flutter side and
  /// passed to both surfaces. The endpoint is grounded only on this payload;
  /// it does NOT read items server-side.
  Future<String> fetchPlanGuidance({
    required Map<String, dynamic> todayContext,
    DateTime? now,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final stream = await _client.stream(
      'v2/plan/guidance',
      body: {
        'today_context': todayContext,
        if (now != null) 'now_iso': now.toUtc().toIso8601String(),
      },
    );

    final buffer = StringBuffer();
    String pending = '';

    final completer = Completer<String>();
    late StreamSubscription<String> sub;
    sub = stream.transform(utf8.decoder).timeout(timeout).listen(
      (chunk) {
        pending += chunk;
        var idx = pending.indexOf('\n');
        while (idx != -1) {
          final line = pending.substring(0, idx);
          pending = pending.substring(idx + 1);
          final parsed = _parseLine(line);
          if (parsed is ChatStreamText) buffer.write(parsed.text);
          if (parsed is _Done) {
            sub.cancel();
            if (!completer.isCompleted) completer.complete(buffer.toString());
            return;
          }
          idx = pending.indexOf('\n');
        }
      },
      onError: (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      },
      onDone: () {
        if (pending.isNotEmpty) {
          final parsed = _parseLine(pending);
          if (parsed is ChatStreamText) buffer.write(parsed.text);
        }
        if (!completer.isCompleted) completer.complete(buffer.toString());
      },
      cancelOnError: true,
    );

    return completer.future;
  }

  /// Returns one of: [ChatStreamText], [ChatStreamToolStart], [_Done], or null.
  static Object? _parseLine(String raw) {
    if (raw.startsWith('data: ')) {
      return ChatStreamText(raw.substring(6).replaceAll('__CRLF__', '\n'));
    }
    if (raw.startsWith('think: ')) {
      final body = raw.substring(7);
      // Strip optional "|app_id:<id>" suffix — surface only the human label.
      final pipeIdx = body.indexOf('|app_id:');
      final label = (pipeIdx >= 0 ? body.substring(0, pipeIdx) : body).trim();
      if (label.isEmpty) return null;
      return ChatStreamToolStart(label);
    }
    if (raw.startsWith('done: ')) return const _Done();
    // tool_result: <base64> intentionally ignored for now — rich-card rendering
    // is a future enhancement.
    return null;
  }
}

class _Done {
  const _Done();
}
