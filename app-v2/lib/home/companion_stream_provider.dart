import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:hive/hive.dart';

import 'package:nooto_v2/companion/companion_signals.dart';
import 'package:nooto_v2/home/cards/morning_brief_card.dart';
import 'package:nooto_v2/home/cards/welcome_card.dart';
import 'package:nooto_v2/home/companion_card.dart';
import 'package:nooto_v2/home/home_storage.dart';
import 'package:nooto_v2/providers/action_items_provider.dart';
import 'package:nooto_v2/services/chat_service.dart';

/// Coalesce window for brief invalidation after `ActionItemsProvider` notifies.
/// A flapping Jira poll (sub-minute cadence) would otherwise burn one LLM call
/// per notify. 5s is below human awareness for "is the brief stale?" while
/// capping LLM cost worst-case at ~12/min, typical 1–2/min.
const Duration _briefDebounce = Duration(seconds: 5);

/// Window for "due soon" classification in the today_context. Items with
/// `dueAt` between now and now+4h surface as `due_soon`; mid-day chip
/// emphasis (priority-1 brandPrimary border) is reserved for this window
/// + overdue. Per DESIGN.md decision 7B (2026-05-05).
const Duration _dueSoonWindow = Duration(hours: 4);

/// Stuck-Jira threshold matching the prior `jiraStuckIssuesCardFor` filter.
/// An incomplete Jira item whose status hasn't moved in this many days
/// becomes a `stuck_jira` entry.
const int _stuckThresholdDays = 3;

/// Screen-scoped provider that owns the Home card stream.
///
/// Lifecycle: instantiated in `HomeScreen.build` via `ChangeNotifierProvider`,
/// disposed when the screen unmounts. Hive boxes are the durable source of
/// truth — provider just reads them on init and writes back on action.
///
/// Generators are registered in [_runGenerators]. Each new card type adds one
/// entry there + one fromJson registration in [_fromJson]; nothing else here
/// changes when the card vocabulary grows.
class CompanionStreamProvider extends ChangeNotifier {
  CompanionStreamProvider({
    required CompanionSignals signals,
    required ActionItemsProvider actionItems,
    required ChatService chatService,
  }) : _signals = signals,
       _actionItems = actionItems,
       _chatService = chatService {
    _actionItems.addListener(_onActionItemsChanged);
    _init();
  }

  final CompanionSignals _signals;
  final ActionItemsProvider _actionItems;
  final ChatService _chatService;
  final List<CompanionCard> _cards = [];
  bool _ready = false;
  bool _briefInFlight = false;
  bool _disposed = false;
  Timer? _briefRefreshDebounce;

  void _onActionItemsChanged() {
    // Card list re-runs synchronously — generator output may shift (e.g. the
    // welcome card's pendant signal is unaffected, but future generators
    // could read action items).
    _runGenerators();
    _persist();
    notifyListeners();
    // Debounced brief invalidation. ActionItemsProvider can notify multiple
    // times in quick succession (Jira poll batches; user marking several
    // items done in a sweep). Coalesce to one re-fetch after the dust
    // settles. Visible to user via the "synthesized Nh ago" timestamp.
    _scheduleBriefRefresh();
  }

  void _scheduleBriefRefresh() {
    _briefRefreshDebounce?.cancel();
    _briefRefreshDebounce = Timer(_briefDebounce, () {
      if (_disposed) return;
      _invalidateAndRefetchBrief();
    });
  }

  Future<void> _invalidateAndRefetchBrief() async {
    final dateKey = _todayLocalKey();
    // Clear today's cached entry so _kickOffMorningBrief proceeds past the
    // cache short-circuit. The in-flight guard inside the kickoff handles
    // overlapping calls.
    await _briefBox.delete(dateKey);
    if (_disposed) return;
    await _kickOffMorningBrief();
  }

  @override
  void dispose() {
    _disposed = true;
    _briefRefreshDebounce?.cancel();
    _actionItems.removeListener(_onActionItemsChanged);
    super.dispose();
  }

  List<CompanionCard> get cards => List.unmodifiable(_cards);
  bool get ready => _ready;

  /// True while a brief LLM fetch is in flight. Drives the small refresh-
  /// affordance spinner on `MorningBriefCard` so the user gets immediate
  /// feedback that their tap registered.
  bool get briefInFlight => _briefInFlight;

  Box<Map> get _cardsBox => Hive.box<Map>(HomeBoxes.cards);
  Box<Map> get _actionsBox => Hive.box<Map>(HomeBoxes.actions);
  Box<Map> get _briefBox => Hive.box<Map>(HomeBoxes.brief);

  Future<void> _init() async {
    try {
      _hydrateFromHive();
      _runGenerators();
      _persist();
      // Trigger the first action-items fetch from here so the widget tree
      // doesn't have to. Defer to next frame — the constructor runs during
      // the consumer's build, and ActionItemsProvider.fetchAll fires its
      // own notifyListeners synchronously, which would throw "setState
      // called during build" if we kicked off here.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        unawaited(_actionItems.kickOffIfNeeded());
      });
      unawaited(_kickOffMorningBrief());
    } catch (e, st) {
      debugPrint('[CompanionStream] init failed: $e\n$st');
      // Fail-soft: empty stream, no crash. User sees only the welcome
      // card on next generator pass (which still runs on `refresh`).
    } finally {
      _ready = true;
      notifyListeners();
    }
  }

  void _hydrateFromHive() {
    _cards.clear();
    final now = DateTime.now();
    final today = _todayLocalKey();
    for (final raw in _cardsBox.values.toList()) {
      try {
        final json = Map<String, dynamic>.from(raw);
        final card = _fromJson(json);
        if (card == null) continue;
        if (card.generatedAt.add(card.ttl).isBefore(now)) {
          _cardsBox.delete(card.id);
          continue;
        }
        // Brief cards carry a dateKey. We only ever want today's; yesterday's
        // brief stays cached in _briefBox under its own date but must not
        // leak into the visible stream past local midnight.
        if (card is MorningBriefCard && card.dateKey != today) {
          _cardsBox.delete(card.id);
          continue;
        }
        // Pre-title-schema briefs (no `title=` attribute on inline tags)
        // render badly when refs go stale (literal `<plan id="ULID"/>`
        // visible to user). Detect and discard at hydration so the next
        // brief fetch repopulates with the new format. Mirrors the same
        // check in `_cachedBriefCard` for the parallel briefBox.
        if (card is MorningBriefCard && _briefBodyMissingTitleAttribute(card.body)) {
          debugPrint('[CompanionStream] discarding pre-title-schema brief from cardsBox at hydration');
          _cardsBox.delete(card.id);
          _briefBox.delete(card.dateKey);
          continue;
        }
        _cards.add(card);
      } catch (e) {
        debugPrint('[CompanionStream] skipped bad card: $e');
      }
    }
    _cards.sort((a, b) => b.priority.compareTo(a.priority));
  }

  /// Runs every registered generator and emits new cards into the stream.
  /// Idempotent — skips emit if a card with the same id already exists or is
  /// dismissed in `home.actions.v1`.
  ///
  /// Post brief-as-coordinator redesign (2026-05-05), the Home stream emits
  /// only voice cards: welcome (priority 1000) and brief (750). The retired
  /// JiraStuckIssuesCard (800) and TodayCard (500) data folds into the brief
  /// generator's `today_context` payload — see `_buildTodayContext`.
  void _runGenerators() {
    _maybeEmit(welcomeCardFor(_signals));
    _replaceOrEmit(_cachedBriefCard());
  }

  /// Synchronous read of today's brief from Hive. Network fetch lives in
  /// [_kickOffMorningBrief]; this just surfaces an already-cached entry so
  /// generator passes don't flicker the brief in/out.
  ///
  /// Briefs cached before the 2026-05-05 chip-title schema change emit
  /// inline tags WITHOUT the `title=` attribute. Those bodies render badly
  /// when refs go stale (literal `<plan id="ULID"/>` text). Detect and
  /// discard them so the next `_kickOffMorningBrief` repopulates with the
  /// new format.
  MorningBriefCard? _cachedBriefCard() {
    final dateKey = _todayLocalKey();
    final raw = _briefBox.get(dateKey);
    if (raw == null) return null;
    try {
      final card = MorningBriefCard.fromJson(Map<String, dynamic>.from(raw));
      if (_briefBodyMissingTitleAttribute(card.body)) {
        debugPrint('[CompanionStream] discarding pre-title-schema brief, will refetch');
        _briefBox.delete(dateKey);
        return null;
      }
      return card;
    } catch (_) {
      return null;
    }
  }

  /// True when the body contains at least one `<plan/>` or `<ticket/>` tag
  /// without a `title=` attribute. Plain-prose bodies (zero tags) and new-
  /// format bodies (every tag has `title=`) both return false.
  static final RegExp _oldFormatTag = RegExp(r'<\s*(ticket|plan)\s+id\s*=\s*"[^"]+"\s*/\s*>');
  bool _briefBodyMissingTitleAttribute(String body) {
    return _oldFormatTag.hasMatch(body);
  }

  /// Cache contract: one network call per device per day under steady state.
  /// The cache hit at the top short-circuits every subsequent same-day call;
  /// `_invalidateAndRefetchBrief` deletes the entry on debounced action-item
  /// notifies, allowing this method to fetch a fresh brief reflecting the
  /// new state. The miss path writes to Hive immediately on success so a
  /// fast second mount (screen rebuild during the in-flight fetch) sees the
  /// entry. Errors are NOT cached — including the backend's `agentic.py`
  /// fallback string, which we detect and discard so a failed fetch doesn't
  /// poison the next 24h of opens.
  ///
  /// Empty-state gate: when [_buildTodayContext] returns no actionable items,
  /// the brief is skipped entirely. Home renders welcome + composer only
  /// (per DESIGN.md state-variants table — silence is the empowerment signal).
  Future<void> _kickOffMorningBrief() async {
    final dateKey = _todayLocalKey();
    if (_briefBox.get(dateKey) != null) return;
    if (_briefInFlight) return;

    final todayContext = _buildTodayContext();
    if (_isContextEmpty(todayContext)) {
      // Nothing to brief on. Skip the LLM call. Welcome card carries the day.
      return;
    }

    _briefInFlight = true;
    try {
      final body = await _chatService.fetchBrief(prompt: _briefPrompt, todayContext: todayContext);
      if (_disposed) return;
      final trimmed = body.trim();
      if (trimmed.isEmpty) {
        _emitFallbackBrief(dateKey, todayContext);
        return;
      }
      if (_looksLikeBackendError(trimmed)) {
        debugPrint(
          '[CompanionStream] brief returned backend fallback, '
          'not caching: $trimmed',
        );
        _emitFallbackBrief(dateKey, todayContext);
        return;
      }
      _logVoiceViolations(trimmed);
      final card = MorningBriefCard(
        dateKey: dateKey,
        greeting: _greetingFor(_signals.preferredName),
        body: trimmed,
        generatedAt: DateTime.now(),
      );
      await _briefBox.put(dateKey, card.toJson());
      if (_disposed) return;
      _replaceOrEmit(card);
      _persist();
      notifyListeners();
    } catch (e) {
      debugPrint('[CompanionStream] brief fetch failed: $e');
      if (!_disposed) _emitFallbackBrief(dateKey, todayContext);
    } finally {
      _briefInFlight = false;
    }
  }

  /// On generator failure (LLM throws, returns empty, returns the backend
  /// error sentinel), render a plain non-coordinated brief: a descriptive
  /// list of items as plain text, no narrative wrapper. NOT cached — the
  /// next mount or the next debounced refresh will retry the real fetch.
  /// Per DESIGN.md state-variants table.
  void _emitFallbackBrief(String dateKey, Map<String, dynamic> todayContext) {
    final body = _composeFallbackBody(todayContext);
    if (body.isEmpty) return;
    final card = MorningBriefCard(
      dateKey: dateKey,
      greeting: _greetingFor(_signals.preferredName),
      body: body,
      generatedAt: DateTime.now(),
    );
    _replaceOrEmit(card);
    notifyListeners();
  }

  String _composeFallbackBody(Map<String, dynamic> ctx) => composeFallbackBriefBody(ctx);

  /// Backend's agentic chat path returns this exact string on any LLM
  /// exception (see `backend/utils/retrieval/agentic.py:427`). It looks like
  /// a successful response from our wire-protocol POV, so we sniff it here.
  bool _looksLikeBackendError(String body) {
    final lower = body.toLowerCase();
    return lower.contains('encountered an error') && lower.contains('try again');
  }

  /// Logs forbidden phrases the brief LLM should never emit. Detection only —
  /// no render redaction (per `/plan-eng-review` 1C decision: prompt-only
  /// enforcement, regex as quality signal). Surface in dogfood logs and
  /// iterate on the prompt if violations stay non-zero.
  void _logVoiceViolations(String body) {
    final hits = findVoiceViolations(body);
    if (hits.isNotEmpty) {
      debugPrint('[CompanionStream] brief voice violation: ${hits.join(", ")} in body: $body');
    }
  }

  Map<String, dynamic> _buildTodayContext() => buildTodayContext(_actionItems.items, now: DateTime.now());

  bool _isContextEmpty(Map<String, dynamic> ctx) => isTodayContextEmpty(ctx);

  /// Voice-and-grammar contract for the brief generator. Drives the
  /// chip-rich coordinator output the new Home depends on. Updated 2026-05-05
  /// per the brief-as-coordinator redesign.
  static const String _briefPrompt =
      "You are Nooto, a calm chief-of-staff briefing the user on today. The "
      "<today_context> system block names the user's overdue items, due-soon "
      "items, stuck Jira tickets, and plan remaining count. Synthesize a "
      "brief in at most 2 sentences that NAMES the actionable items inline.\n"
      "\n"
      "Voice rules (hard):\n"
      "- Descriptive, not imperative. State facts. Do not coach, lecture, "
      "or moralize.\n"
      "- Forbidden phrases: 'you missed it', 'drowning', 'knock it out', "
      "'you'll keep', 'still drowning'. Any second-person imperative is wrong.\n"
      "- Bad example: 'Yesterday was empty. You missed task #3 — knock it out "
      "or you'll keep drowning.' (Scolding. Imperative. Forbidden.)\n"
      "- Good example: 'Today: 1 overdue (<plan id=\"plan-1\"/>) and 3 stuck "
      "Jira tickets (<ticket id=\"WPNG-2951\"/>, <ticket id=\"WPNG-3402\"/>, "
      "<ticket id=\"WPNG-3415\"/>).' (Facts. Inline chips. Forward-looking.)\n"
      "\n"
      "Inline chip emission:\n"
      "- Reference action items with the self-closing tag "
      "<plan id=\"X\" title=\"Y\"/>. X is the id from today_context.overdue[].id "
      "or today_context.due_soon[].id; Y is the matching .title (verbatim, no "
      "rephrasing, no quotes inside).\n"
      "- Reference Jira tickets with <ticket id=\"WPNG-X\" title=\"Y\"/>. X is "
      "the id from today_context.stuck_jira[].id; Y is the matching .title.\n"
      "- The title attribute is REQUIRED on every tag — it's the human-readable "
      "fallback the renderer uses when the chip can't resolve to a live item.\n"
      "- Never invent ids. Use only ids present in today_context.\n"
      "- Do NOT put extra whitespace around tags inside parentheses. Write "
      "`(<ticket id=\"A\"/>, <ticket id=\"B\"/>)` not `( <ticket id=\"A\"/> , <ticket id=\"B\"/> )`. "
      "Treat tags as words: punctuation hugs them.\n"
      "\n"
      "Chip cap (priority order — keep at most 4 chips total):\n"
      "1. overdue (highest)\n"
      "2. due_soon (next 4h)\n"
      "3. stuck_jira (oldest first)\n"
      "4. plan refs (lowest)\n"
      "Items beyond the cap collapse to a count phrase: '…and N more stuck' "
      "or 'and N more overdue'. Keep the prose grammatical.\n"
      "\n"
      "If today_context.plan_remaining_count is large (>5) and few chips are "
      "shown, append 'N items still on this week's plan.' as a closing fact.";

  String _greetingFor(String? name) {
    final hour = DateTime.now().hour;
    final salutation = hour < 11
        ? 'Good morning'
        : hour < 17
        ? 'Good afternoon'
        : hour < 22
        ? 'Good evening'
        : 'Hi';
    final n = (name ?? '').trim();
    return n.isEmpty ? '$salutation.' : '$salutation, $n.';
  }

  String _todayLocalKey() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Today card is regenerated each pass with fresh content, so unlike most
  /// cards we want the latest copy in the stream — drop any prior instance
  /// before emitting the new one. Dismiss/snooze suppression still applies.
  void _replaceOrEmit(CompanionCard? card) {
    if (card == null) return;
    if (_isDismissed(card.id)) return;
    if (_isSnoozed(card.id)) return;
    _cards.removeWhere((c) => c.id == card.id);
    _cards.add(card);
    _cards.sort((a, b) => b.priority.compareTo(a.priority));
  }

  void _maybeEmit(CompanionCard? card) {
    if (card == null) return;
    if (_cards.any((c) => c.id == card.id)) return;
    if (_isDismissed(card.id)) return;
    if (_isAccepted(card.id)) return;
    if (_isSnoozed(card.id)) return;
    _cards.add(card);
    _cards.sort((a, b) => b.priority.compareTo(a.priority));
  }

  bool _isDismissed(String cardId) {
    final raw = _actionsBox.get(_actionKey(cardId, CardAction.dismiss));
    return raw != null;
  }

  bool _isAccepted(String cardId) {
    final raw = _actionsBox.get(_actionKey(cardId, CardAction.accept));
    return raw != null;
  }

  bool _isSnoozed(String cardId) {
    final raw = _actionsBox.get(_actionKey(cardId, CardAction.snooze));
    if (raw == null) return false;
    final until = raw['until'] as int?;
    if (until == null) return false;
    return DateTime.now().millisecondsSinceEpoch < until;
  }

  /// Refreshes the stream — re-runs generators against current state. Called
  /// on Home foreground or when an action mutates state in a way that should
  /// trigger re-evaluation.
  Future<void> refresh() async {
    _hydrateFromHive();
    _runGenerators();
    _persist();
    notifyListeners();
  }

  /// User-initiated full refresh. Single entry point for the pull-to-refresh
  /// gesture and the inline refresh icon, so both surfaces produce identical
  /// end state and never race the action-items debounce path into a duplicate
  /// LLM call.
  Future<void> forceRefreshBrief() async {
    try {
      await _actionItems.fetchAll();
    } catch (e) {
      debugPrint('[CompanionStream] force refresh: action items fetch failed: $e');
      // Fall through to brief refetch anyway — the local items are still
      // a valid grounding for the brief.
    }
    if (_disposed) return;
    // _onActionItemsChanged ran during the await above and (re)scheduled the
    // 5s debounced brief refresh. Cancel it — we're about to fetch directly,
    // and letting the debounce fire would double-bill the LLM.
    _briefRefreshDebounce?.cancel();
    await _invalidateAndRefetchBrief();
  }

  /// Records an action and removes the card from the active stream. Dismissed
  /// cards stay suppressed via `_isDismissed`; snoozed cards re-emerge once
  /// `now > until`.
  Future<void> recordAction(CompanionCard card, CardAction action, {DateTime? snoozeUntil}) async {
    await _actionsBox.put(_actionKey(card.id, action), {
      'id': card.id,
      'action': action.code,
      'ts': DateTime.now().millisecondsSinceEpoch,
      if (snoozeUntil != null) 'until': snoozeUntil.millisecondsSinceEpoch,
    });
    final removesFromStream =
        action == CardAction.accept || action == CardAction.dismiss || action == CardAction.snooze;
    if (removesFromStream) {
      _cards.removeWhere((c) => c.id == card.id);
      await _cardsBox.delete(card.id);
      notifyListeners();
    }
  }

  void _persist() {
    for (final card in _cards) {
      _cardsBox.put(card.id, card.toJson());
    }
  }

  String _actionKey(String cardId, CardAction action) => '$cardId::${action.code}';
}

/// Card-type registry: dispatches deserialization on the `kind` field. Adding
/// a new card type requires one line here.
/// Builds the structured grounding the brief LLM uses to emit chip refs by
/// id. Shape: `{ overdue: [...], due_soon: [...], stuck_jira: [...], plan_remaining_count: N }`.
/// Empty arrays are kept (not omitted) so the prompt can deterministically
/// branch on each bucket. Pure function — no provider/state dependencies —
/// so unit tests pin the bucketing rules without spinning up Hive. Also used
/// by the Plan tab's `PlanGuidanceProvider` (same shape, same backend
/// grounding contract).
Map<String, dynamic> buildTodayContext(Iterable<ActionItem> items, {required DateTime now}) {
  final dueSoonCutoff = now.add(_dueSoonWindow);
  final overdue = <Map<String, dynamic>>[];
  final dueSoon = <Map<String, dynamic>>[];
  final stuckJira = <Map<String, dynamic>>[];
  var planRemainingCount = 0;
  var waitingOnOthersCount = 0;
  for (final item in items) {
    if (item.completed) continue;
    // Jira terminal-states design (2026-05-17): an item counts toward
    // `plan_remaining_count` only when the user is the next actor. Items
    // parked with a reviewer/QA/blocker move to `waiting_on_others_count`.
    // Null (non-Jira items, or Jira items the classifier hasn't seen yet)
    // preserves today's behavior: counted as "on plate".
    final actionability = _readActionability(item.externalSource?.metadata);
    final offPlate = actionability == 'waiting' || actionability == 'blocked';
    if (offPlate) {
      waitingOnOthersCount++;
    } else {
      planRemainingCount++;
    }
    // Off-plate items (user-overridden as waiting/blocked) are excluded from
    // the focal-item candidates the brief picks from. The user said "this is
    // not on me" — surfacing it as something to act on contradicts the override.
    // Items with null actionability (non-Jira or unclassified Jira) still flow
    // through the chip lists per today's behavior.
    if (offPlate) continue;
    final due = item.dueAt;
    if (due != null) {
      if (due.isBefore(now)) {
        overdue.add({
          'id': item.id,
          'title': item.description,
          'due_at': due.toUtc().toIso8601String(),
          'source': item.externalSource?.source ?? 'transcript',
        });
        continue;
      }
      if (due.isBefore(dueSoonCutoff)) {
        dueSoon.add({
          'id': item.id,
          'title': item.description,
          'due_at': due.toUtc().toIso8601String(),
          'source': item.externalSource?.source ?? 'transcript',
        });
        continue;
      }
    }
    final ext = item.externalSource;
    if (ext != null && ext.source == 'jira') {
      final days = ext.daysAtStatus;
      if (days != null && days >= _stuckThresholdDays) {
        stuckJira.add({'id': ext.externalId, 'title': item.description, 'age_in_days': days, 'source': 'jira'});
      }
    }
    // Otherwise: counted in plan_remaining_count but not surfaced as a chip.
  }
  return {
    'overdue': overdue,
    'due_soon': dueSoon,
    'stuck_jira': stuckJira,
    'plan_remaining_count': planRemainingCount,
    // Additive — emit only when non-zero so old prompt readers / payload
    // consumers don't trip on a missing/zero key.
    if (waitingOnOthersCount > 0) 'waiting_on_others_count': waitingOnOthersCount,
  };
}

/// Defensive read of `metadata.actionability` written by the backend Jira
/// classifier (`backend/utils/integrations/jira_status_classifier.py`).
/// Returns the value only when it's one of the three known buckets; null,
/// missing key, non-string, or any unrecognized value all collapse to null
/// — equivalent to the "self" bucket for counting purposes.
String? _readActionability(Map<String, dynamic>? metadata) {
  final raw = metadata?['actionability'];
  if (raw is! String) return null;
  if (raw == 'self' || raw == 'waiting' || raw == 'blocked') return raw;
  return null;
}

/// True when no actionable items exist (overdue/due-soon/stuck all empty).
/// Used as the empty-state gate that skips the brief LLM call entirely.
/// Also used by the Plan tab to suppress the guidance LLM call on calm days.
bool isTodayContextEmpty(Map<String, dynamic> ctx) {
  final overdue = (ctx['overdue'] as List?)?.isEmpty ?? true;
  final dueSoon = (ctx['due_soon'] as List?)?.isEmpty ?? true;
  final stuck = (ctx['stuck_jira'] as List?)?.isEmpty ?? true;
  return overdue && dueSoon && stuck;
}

/// Forbidden phrases the brief LLM should never emit. Detection only — no
/// render redaction. Surface in dogfood logs and iterate on the prompt.
@visibleForTesting
final RegExp briefForbiddenVoicePattern = RegExp(
  r"\b(you missed it|drowning|knock it out|you'll keep|you[’]ll keep|still drowning)\b",
  caseSensitive: false,
);

/// Returns the list of forbidden-phrase matches in [body], lower-cased.
/// Pure function — surfaced for unit tests.
@visibleForTesting
List<String> findVoiceViolations(String body) {
  return briefForbiddenVoicePattern.allMatches(body).map((m) => m.group(0)!.toLowerCase()).toList();
}

/// Plain-text fallback brief composed when the LLM fetch fails. Shape mirrors
/// `_composeFallbackBody`'s output. Exposed for unit tests.
@visibleForTesting
String composeFallbackBriefBody(Map<String, dynamic> ctx) {
  final overdue = (ctx['overdue'] as List?)?.length ?? 0;
  final dueSoon = (ctx['due_soon'] as List?)?.length ?? 0;
  final stuck = (ctx['stuck_jira'] as List?)?.length ?? 0;
  final parts = <String>[];
  if (overdue > 0) parts.add('$overdue overdue');
  if (dueSoon > 0) parts.add('$dueSoon due soon');
  if (stuck > 0) parts.add('$stuck stuck');
  if (parts.isEmpty) return '';
  return 'Today: ${parts.join(", ")}.';
}

CompanionCard? _fromJson(Map<String, dynamic> json) {
  final kindCode = json['kind'] as String?;
  if (kindCode == null) return null;
  final kind = CardKindCodec.fromCode(kindCode);
  switch (kind) {
    case CardKind.welcome:
      return WelcomeCard.fromJson(json);
    case CardKind.brief:
      return MorningBriefCard.fromJson(json);
    case CardKind.actionItem:
    case CardKind.jiraStuckIssues:
      // Retired 2026-05-05 (brief-as-coordinator redesign). Cached entries
      // from prior versions silently skip — `_hydrateFromHive` will purge
      // them via the try/catch on next pass when fromJson returns null.
      return null;
    case CardKind.commitmentCapture:
    case CardKind.focusBlock:
    case CardKind.relationshipNudge:
      // Day 30+ kinds — generators not yet implemented.
      return null;
  }
}
