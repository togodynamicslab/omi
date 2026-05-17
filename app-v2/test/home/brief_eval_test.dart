import 'package:flutter_test/flutter_test.dart';

import 'package:nooto_v2/home/companion_stream_provider.dart';
import 'package:nooto_v2/providers/action_items_provider.dart';

/// Brief eval suite — fixture-driven assertions on the pure pieces of the
/// brief coordinator. Replaces a real LLM eval (which would require backend
/// connectivity in CI) with deterministic checks on the inputs and outputs
/// the coordinator builds: today_context bucketing, empty-state gate, voice
/// violation regex, and fallback body shape.
///
/// Per /plan-eng-review 3A: 5+ fixture cases (happy path, voice violations,
/// overflow, Jira-only, plan-only, empty). Real LLM behavior is verified in
/// dogfood, not CI.

DateTime _nowFixture() => DateTime(2026, 5, 5, 13, 0); // 2026-05-05 13:00 local

ActionItem _planItem({required String id, required String title, DateTime? dueAt, bool completed = false}) {
  return ActionItem(id: id, description: title, completed: completed, dueAt: dueAt);
}

ActionItem _jiraItem({
  required String id,
  required String externalId,
  required String title,
  required int daysAtStatus,
  bool completed = false,
}) {
  // Reverse-engineer a `status_changed_at` so daysAtStatus produces the value
  // the test asserts. ExternalSource.daysAtStatus reads metadata.status_changed_at.
  final now = _nowFixture();
  final statusChangedAt = now.subtract(Duration(days: daysAtStatus));
  return ActionItem(
    id: id,
    description: title,
    completed: completed,
    externalSource: ExternalSource(
      source: 'jira',
      externalId: externalId,
      url: 'https://x.atlassian.net/browse/$externalId',
      metadata: {'status_changed_at': statusChangedAt.toUtc().toIso8601String()},
    ),
  );
}

/// Jira item whose backend classifier landed an `actionability` verdict
/// (`self`, `waiting`, or `blocked`). Used by the Lane D fixtures below to
/// pin how the brief LLM is fed when the on-plate vs waiting-on-others split
/// matters. No `status_changed_at` so the item never lands in `stuck_jira`
/// — keeps the fixture pure to the waiting-on-others axis.
ActionItem _classifiedJiraItem({
  required String externalId,
  required String title,
  required String actionability,
  bool completed = false,
}) {
  return ActionItem(
    id: externalId,
    description: title,
    completed: completed,
    externalSource: ExternalSource(
      source: 'jira',
      externalId: externalId,
      url: 'https://x.atlassian.net/browse/$externalId',
      metadata: {'actionability': actionability},
    ),
  );
}

void main() {
  group('Fixture 1: empty (happy quiet day)', () {
    test('zero items → empty buckets, plan_remaining_count 0', () {
      final ctx = buildTodayContext(const <ActionItem>[], now: _nowFixture());
      expect(ctx['overdue'], isEmpty);
      expect(ctx['due_soon'], isEmpty);
      expect(ctx['stuck_jira'], isEmpty);
      expect(ctx['plan_remaining_count'], 0);
      expect(isTodayContextEmpty(ctx), isTrue);
    });

    test('only completed items → empty + plan_remaining_count 0', () {
      final ctx = buildTodayContext([
        _planItem(id: 'p1', title: 'Done', completed: true),
        _planItem(id: 'p2', title: 'Also done', completed: true),
      ], now: _nowFixture());
      expect(ctx['plan_remaining_count'], 0);
      expect(isTodayContextEmpty(ctx), isTrue);
    });
  });

  group('Fixture 2: overdue happy path', () {
    test('one overdue item lands in overdue bucket only', () {
      final ctx = buildTodayContext([
        _planItem(id: 'plan-1', title: 'Plan the week', dueAt: _nowFixture().subtract(const Duration(hours: 14))),
      ], now: _nowFixture());
      final overdue = ctx['overdue'] as List;
      expect(overdue, hasLength(1));
      expect(overdue.first['id'], 'plan-1');
      expect(overdue.first['title'], 'Plan the week');
      expect(overdue.first['source'], 'transcript');
      expect(ctx['due_soon'], isEmpty);
      expect(isTodayContextEmpty(ctx), isFalse);
    });
  });

  group('Fixture 3: due-soon (within 4h) classification', () {
    test('item due in 2h goes into due_soon, not overdue', () {
      final ctx = buildTodayContext([
        _planItem(id: 'plan-2', title: 'Brief Acme call', dueAt: _nowFixture().add(const Duration(hours: 2))),
      ], now: _nowFixture());
      expect(ctx['overdue'], isEmpty);
      expect(ctx['due_soon'], hasLength(1));
      expect((ctx['due_soon'] as List).first['id'], 'plan-2');
    });

    test('item due in 5h does NOT go into due_soon (4h cutoff)', () {
      final ctx = buildTodayContext([
        _planItem(id: 'plan-3', title: 'Tomorrow stuff', dueAt: _nowFixture().add(const Duration(hours: 5))),
      ], now: _nowFixture());
      expect(ctx['overdue'], isEmpty);
      expect(ctx['due_soon'], isEmpty);
      // Counted in plan_remaining_count but not surfaced as a chip.
      expect(ctx['plan_remaining_count'], 1);
    });
  });

  group('Fixture 4: Jira-only', () {
    test('stuck Jira ticket (>=3 days at status) lands in stuck_jira', () {
      final ctx = buildTodayContext([
        _jiraItem(id: 'j1', externalId: 'WPNG-2951', title: 'CSV import', daysAtStatus: 5),
      ], now: _nowFixture());
      expect(ctx['overdue'], isEmpty);
      expect(ctx['due_soon'], isEmpty);
      final stuck = ctx['stuck_jira'] as List;
      expect(stuck, hasLength(1));
      expect(stuck.first['id'], 'WPNG-2951');
      expect(stuck.first['title'], 'CSV import');
      expect(stuck.first['age_in_days'], 5);
      expect(stuck.first['source'], 'jira');
      expect(isTodayContextEmpty(ctx), isFalse);
    });

    test('Jira ticket at status only 1 day is NOT stuck', () {
      final ctx = buildTodayContext([
        _jiraItem(id: 'j2', externalId: 'WPNG-1', title: 'fresh', daysAtStatus: 1),
      ], now: _nowFixture());
      expect(ctx['stuck_jira'], isEmpty);
      expect(isTodayContextEmpty(ctx), isTrue);
      // Still counted as remaining plan work.
      expect(ctx['plan_remaining_count'], 1);
    });
  });

  group('Fixture 5: mixed (overflow scenario)', () {
    test('1 overdue + 5 stuck + 30 plan-only items populate buckets and count', () {
      final items = <ActionItem>[
        _planItem(id: 'plan-1', title: 'Plan the week', dueAt: _nowFixture().subtract(const Duration(hours: 14))),
        for (var i = 0; i < 5; i++)
          _jiraItem(id: 'j$i', externalId: 'WPNG-${100 + i}', title: 'stuck $i', daysAtStatus: 3 + i),
        for (var i = 0; i < 30; i++) _planItem(id: 'pn$i', title: 'plan $i'),
      ];
      final ctx = buildTodayContext(items, now: _nowFixture());
      expect((ctx['overdue'] as List).length, 1);
      expect((ctx['stuck_jira'] as List).length, 5);
      expect(ctx['plan_remaining_count'], 1 + 5 + 30);
      expect(isTodayContextEmpty(ctx), isFalse);
    });
  });

  group('Fixture 6: voice violation regex', () {
    test('catches all forbidden phrases case-insensitively', () {
      final cases = [
        "Yesterday was empty. You missed it.",
        "You'll keep drowning in the other 26 tasks.",
        "Knock it out today.",
        "you missed it",
        "DROWNING",
        "Knock IT out today",
      ];
      for (final body in cases) {
        final hits = findVoiceViolations(body);
        expect(hits, isNotEmpty, reason: 'Expected at least one hit in: $body');
      }
    });

    test('clean copy yields zero hits', () {
      final cleanCases = [
        'Today: 1 overdue (Plan the week) and 3 stuck Jira tickets.',
        'Quiet morning. Nothing on deck.',
        'Yesterday: empty. Today: 2 due in the next 4h.',
        'Plan still open: 12 items.',
      ];
      for (final body in cleanCases) {
        expect(findVoiceViolations(body), isEmpty, reason: 'Did not expect a hit in clean body: $body');
      }
    });
  });

  group('Fixture 7: fallback brief body composition', () {
    test('plain text shape: "Today: N overdue, M due soon, K stuck."', () {
      final ctx = buildTodayContext([
        _planItem(id: 'plan-1', title: 'Plan the week', dueAt: _nowFixture().subtract(const Duration(hours: 14))),
        _jiraItem(id: 'j1', externalId: 'WPNG-2951', title: 'CSV', daysAtStatus: 5),
        _jiraItem(id: 'j2', externalId: 'WPNG-3402', title: 'Enrich', daysAtStatus: 4),
      ], now: _nowFixture());
      expect(composeFallbackBriefBody(ctx), 'Today: 1 overdue, 2 stuck.');
    });

    test('empty context yields empty fallback body (no card emitted)', () {
      final ctx = buildTodayContext(const <ActionItem>[], now: _nowFixture());
      expect(composeFallbackBriefBody(ctx), '');
    });
  });

  // ---------------------------------------------------------------------------
  // Lane D — Jira terminal-states design (2026-05-17).
  //
  // Brief LLM eval cases for the new `waiting_on_others_count` payload field
  // landed in Lanes A-C. The brief prompt at `backend/utils/llm/plan_guidance.py`
  // now enumerates this field; these fixtures pin the input contract the LLM
  // sees so the on-plate vs waiting-on-others split can never silently regress.
  //
  // This file's eval style is fixture-driven on the pure pieces (today_context
  // shape + fallback body composition) — not a live LLM call. The "brief
  // mentions waiting on others" assertion the design doc lists is pinned here
  // via the payload contract: if the key is present + non-zero, the brief
  // prompt's INPUT enumeration tells the LLM to acknowledge it; if absent,
  // the prompt has nothing to say about it. The live-LLM render check is a
  // skipped variant below (requires backend connectivity).
  // ---------------------------------------------------------------------------

  group('Fixture 8: waiting_on_others_count > 0 (no focal item to pick)', () {
    test('plan_remaining_count=3 + 4 waiting items → payload carries waiting_on_others_count, '
        'no chip buckets, empty-state gate triggers', () {
      final ctx = buildTodayContext([
        // 3 on-plate items — populate plan_remaining_count, no due_at so
        // they never surface as overdue / due_soon chips.
        for (var i = 0; i < 3; i++) _planItem(id: 'pn$i', title: 'plan $i'),
        // 4 waiting/blocked items — route to waiting_on_others_count.
        // Mix of `waiting` and `blocked` to mirror what the classifier
        // produces in real workflows (In Review + Blocked on Legal both
        // count as "off your plate").
        _classifiedJiraItem(externalId: 'WPNG-501', title: 'In Review', actionability: 'waiting'),
        _classifiedJiraItem(externalId: 'WPNG-502', title: 'Awaiting QA', actionability: 'waiting'),
        _classifiedJiraItem(externalId: 'WPNG-503', title: 'Pending Legal', actionability: 'blocked'),
        _classifiedJiraItem(externalId: 'WPNG-504', title: 'Code Review', actionability: 'waiting'),
      ], now: _nowFixture());
      // On-plate count is the 3 plain plan items only. Waiting items are
      // explicitly NOT on plate.
      expect(ctx['plan_remaining_count'], 3);
      expect(ctx['waiting_on_others_count'], 4);
      // No focal item: overdue / due_soon / stuck_jira are all empty, so
      // the brief LLM has nothing to name as the lead chip. This matches
      // the design contract — waiting items are acknowledged in prose but
      // never picked as the focal item (no chip emission path for them).
      expect(ctx['overdue'], isEmpty);
      expect(ctx['due_soon'], isEmpty);
      expect(ctx['stuck_jira'], isEmpty);
      // Empty-state gate triggers (no actionable chip buckets). The brief
      // coordinator's calm-state copy still surfaces the waiting count from
      // the payload — verified live in dogfood, not here.
      expect(isTodayContextEmpty(ctx), isTrue);
    });

    test('completed items never count toward either bucket, even when actionability is set', () {
      final ctx = buildTodayContext([
        // Completed waiting item: drops out entirely.
        _classifiedJiraItem(externalId: 'WPNG-600', title: 'Shipped review', actionability: 'waiting', completed: true),
        // One live waiting item to keep the key non-zero.
        _classifiedJiraItem(externalId: 'WPNG-601', title: 'Still in review', actionability: 'waiting'),
      ], now: _nowFixture());
      expect(ctx['plan_remaining_count'], 0);
      expect(ctx['waiting_on_others_count'], 1);
    });
  });

  group('Fixture 9: waiting_on_others_count absent (calm-state, no Jira parked work)', () {
    test('plan_remaining_count=3 + zero waiting items → key omitted from payload', () {
      final ctx = buildTodayContext([
        for (var i = 0; i < 3; i++) _planItem(id: 'pn$i', title: 'plan $i'),
      ], now: _nowFixture());
      expect(ctx['plan_remaining_count'], 3);
      // Additive contract: the key is OMITTED (not zero) when nothing is
      // waiting. The prompt's INPUT enumeration marks it optional, so the
      // LLM has no signal to mention "waiting on others" / "parked".
      expect(ctx.containsKey('waiting_on_others_count'), isFalse);
      // No actionable chips → empty-state gate → calm-state copy. Reads like
      // today's calm-state output, exactly as the design specifies.
      expect(ctx['overdue'], isEmpty);
      expect(ctx['due_soon'], isEmpty);
      expect(ctx['stuck_jira'], isEmpty);
      expect(isTodayContextEmpty(ctx), isTrue);
    });

    test('all-self actionability classifications still omit the key (zero is omitted, not emitted)', () {
      final ctx = buildTodayContext([
        _classifiedJiraItem(externalId: 'WPNG-700', title: 'Implementing', actionability: 'self'),
        _classifiedJiraItem(externalId: 'WPNG-701', title: 'Coding', actionability: 'self'),
        _classifiedJiraItem(externalId: 'WPNG-702', title: 'In Progress', actionability: 'self'),
      ], now: _nowFixture());
      expect(ctx['plan_remaining_count'], 3);
      expect(ctx.containsKey('waiting_on_others_count'), isFalse);
    });
  });

  // Live-LLM render assertion — verifies the brief LLM actually emits
  // "waiting on others" (or a synonym: parked, with reviewer, waiting) when
  // the payload carries `waiting_on_others_count > 0`, and never emits any
  // of those phrases when the key is absent. Requires a backend connection
  // to the brief generator at `backend/utils/llm/plan_guidance.py`, which
  // isn't wired into the Flutter test harness — there is no in-test LLM
  // call site in this file's parent module. Tagged so CI never runs it;
  // dogfood verification covers the live-text contract.
  group('Fixture 10: live LLM render (skipped — requires backend)', () {
    test(
      'waiting_on_others_count > 0 → brief mentions "waiting on others" or synonym',
      () {},
      skip: 'Requires live brief LLM endpoint; verified in dogfood per Lane D caveat.',
    );
    test(
      'waiting_on_others_count absent → brief never mentions parked/waiting/reviewer phrasing',
      () {},
      skip: 'Requires live brief LLM endpoint; verified in dogfood per Lane D caveat.',
    );
  });
}
