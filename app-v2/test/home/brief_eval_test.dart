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

ActionItem _planItem({
  required String id,
  required String title,
  DateTime? dueAt,
  bool completed = false,
}) {
  return ActionItem(
    id: id,
    description: title,
    completed: completed,
    dueAt: dueAt,
  );
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
      final ctx = buildTodayContext(
        [
          _planItem(id: 'p1', title: 'Done', completed: true),
          _planItem(id: 'p2', title: 'Also done', completed: true),
        ],
        now: _nowFixture(),
      );
      expect(ctx['plan_remaining_count'], 0);
      expect(isTodayContextEmpty(ctx), isTrue);
    });
  });

  group('Fixture 2: overdue happy path', () {
    test('one overdue item lands in overdue bucket only', () {
      final ctx = buildTodayContext(
        [
          _planItem(
            id: 'plan-1',
            title: 'Plan the week',
            dueAt: _nowFixture().subtract(const Duration(hours: 14)),
          ),
        ],
        now: _nowFixture(),
      );
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
      final ctx = buildTodayContext(
        [
          _planItem(
            id: 'plan-2',
            title: 'Brief Acme call',
            dueAt: _nowFixture().add(const Duration(hours: 2)),
          ),
        ],
        now: _nowFixture(),
      );
      expect(ctx['overdue'], isEmpty);
      expect(ctx['due_soon'], hasLength(1));
      expect((ctx['due_soon'] as List).first['id'], 'plan-2');
    });

    test('item due in 5h does NOT go into due_soon (4h cutoff)', () {
      final ctx = buildTodayContext(
        [
          _planItem(
            id: 'plan-3',
            title: 'Tomorrow stuff',
            dueAt: _nowFixture().add(const Duration(hours: 5)),
          ),
        ],
        now: _nowFixture(),
      );
      expect(ctx['overdue'], isEmpty);
      expect(ctx['due_soon'], isEmpty);
      // Counted in plan_remaining_count but not surfaced as a chip.
      expect(ctx['plan_remaining_count'], 1);
    });
  });

  group('Fixture 4: Jira-only', () {
    test('stuck Jira ticket (>=3 days at status) lands in stuck_jira', () {
      final ctx = buildTodayContext(
        [
          _jiraItem(id: 'j1', externalId: 'WPNG-2951', title: 'CSV import', daysAtStatus: 5),
        ],
        now: _nowFixture(),
      );
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
      final ctx = buildTodayContext(
        [_jiraItem(id: 'j2', externalId: 'WPNG-1', title: 'fresh', daysAtStatus: 1)],
        now: _nowFixture(),
      );
      expect(ctx['stuck_jira'], isEmpty);
      expect(isTodayContextEmpty(ctx), isTrue);
      // Still counted as remaining plan work.
      expect(ctx['plan_remaining_count'], 1);
    });
  });

  group('Fixture 5: mixed (overflow scenario)', () {
    test('1 overdue + 5 stuck + 30 plan-only items populate buckets and count', () {
      final items = <ActionItem>[
        _planItem(
          id: 'plan-1',
          title: 'Plan the week',
          dueAt: _nowFixture().subtract(const Duration(hours: 14)),
        ),
        for (var i = 0; i < 5; i++)
          _jiraItem(
            id: 'j$i',
            externalId: 'WPNG-${100 + i}',
            title: 'stuck $i',
            daysAtStatus: 3 + i,
          ),
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
        expect(findVoiceViolations(body), isEmpty,
            reason: 'Did not expect a hit in clean body: $body');
      }
    });
  });

  group('Fixture 7: fallback brief body composition', () {
    test('plain text shape: "Today: N overdue, M due soon, K stuck."', () {
      final ctx = buildTodayContext(
        [
          _planItem(
            id: 'plan-1',
            title: 'Plan the week',
            dueAt: _nowFixture().subtract(const Duration(hours: 14)),
          ),
          _jiraItem(id: 'j1', externalId: 'WPNG-2951', title: 'CSV', daysAtStatus: 5),
          _jiraItem(id: 'j2', externalId: 'WPNG-3402', title: 'Enrich', daysAtStatus: 4),
        ],
        now: _nowFixture(),
      );
      expect(composeFallbackBriefBody(ctx), 'Today: 1 overdue, 2 stuck.');
    });

    test('empty context yields empty fallback body (no card emitted)', () {
      final ctx = buildTodayContext(const <ActionItem>[], now: _nowFixture());
      expect(composeFallbackBriefBody(ctx), '');
    });
  });
}
