import 'package:flutter_test/flutter_test.dart';

import 'package:nooto_v2/home/companion_stream_provider.dart';
import 'package:nooto_v2/providers/action_items_provider.dart';

/// Jira terminal-states design — Lane C1 (2026-05-17).
///
/// `buildTodayContext` now reads `external_source.metadata.actionability`
/// (written backend-side by the LLM Jira status classifier) and routes
/// `waiting` + `blocked` items into a separate `waiting_on_others_count`
/// payload field. `plan_remaining_count` keeps its name but now means
/// "actually on the user's plate" — items with `actionability == "self"`
/// (or null, for non-Jira / unclassified items) only.
///
/// Regression contract: any item whose metadata lacks `actionability` MUST
/// produce the byte-for-byte same payload as before this change. The
/// classifier rolls out asynchronously; existing readers + the LLM brief
/// prompt must keep working unchanged until enriched metadata arrives.

DateTime _nowFixture() => DateTime(2026, 5, 17, 9, 0); // 2026-05-17 09:00 local

ActionItem _itemWithActionability({
  required String id,
  required String title,
  String? actionability, // null = no actionability key on metadata
  bool completed = false,
  bool jiraSource = true,
}) {
  Map<String, dynamic>? metadata;
  if (actionability != null) {
    metadata = {'actionability': actionability};
  } else if (jiraSource) {
    // Unclassified Jira item: still has an externalSource + metadata, just
    // no actionability key yet. Models the pre-classifier-rollout state.
    metadata = const {};
  }
  final externalSource = jiraSource
      ? ExternalSource(source: 'jira', externalId: id, url: 'https://x.atlassian.net/browse/$id', metadata: metadata)
      : null;
  return ActionItem(id: id, description: title, completed: completed, externalSource: externalSource);
}

/// Bare plan item — no externalSource, mirrors a transcript-derived
/// commitment. metadata is therefore absent end-to-end.
ActionItem _planItem({required String id, required String title, bool completed = false}) {
  return ActionItem(id: id, description: title, completed: completed);
}

void main() {
  group('actionability="self"', () {
    test('!completed → counted in plan_remaining_count, not in waiting_on_others_count', () {
      final ctx = buildTodayContext([
        _itemWithActionability(id: 'JIRA-1', title: 'Implement endpoint', actionability: 'self'),
      ], now: _nowFixture());
      expect(ctx['plan_remaining_count'], 1);
      expect(ctx.containsKey('waiting_on_others_count'), isFalse);
    });
  });

  group('actionability="waiting"', () {
    test('!completed → counted in waiting_on_others_count, NOT in plan_remaining_count', () {
      final ctx = buildTodayContext([
        _itemWithActionability(id: 'JIRA-2', title: 'In Review', actionability: 'waiting'),
      ], now: _nowFixture());
      expect(ctx['plan_remaining_count'], 0);
      expect(ctx['waiting_on_others_count'], 1);
    });
  });

  group('actionability="blocked"', () {
    test('!completed → counted in waiting_on_others_count', () {
      final ctx = buildTodayContext([
        _itemWithActionability(id: 'JIRA-3', title: 'Blocked on Legal', actionability: 'blocked'),
      ], now: _nowFixture());
      expect(ctx['plan_remaining_count'], 0);
      expect(ctx['waiting_on_others_count'], 1);
    });
  });

  group('actionability=null', () {
    test('non-Jira plan item → counted in plan_remaining_count (preserves today\'s behavior)', () {
      final ctx = buildTodayContext([_planItem(id: 'plan-1', title: 'Capture from transcript')], now: _nowFixture());
      expect(ctx['plan_remaining_count'], 1);
      expect(ctx.containsKey('waiting_on_others_count'), isFalse);
    });

    test('unclassified Jira item (metadata present, no actionability key) → counted in plan_remaining_count', () {
      final ctx = buildTodayContext([
        _itemWithActionability(id: 'JIRA-4', title: 'Newly seen status'),
      ], now: _nowFixture());
      expect(ctx['plan_remaining_count'], 1);
      expect(ctx.containsKey('waiting_on_others_count'), isFalse);
    });

    test('Jira item with garbage actionability value → treated as null → plan_remaining_count', () {
      // Defensive: classifier schema drift or hand-written override typo
      // must not silently double-count or vanish the item.
      final item = ActionItem(
        id: 'JIRA-5',
        description: 'Weird value',
        completed: false,
        externalSource: ExternalSource(
          source: 'jira',
          externalId: 'JIRA-5',
          url: 'https://x.atlassian.net/browse/JIRA-5',
          metadata: const {'actionability': 'something_unknown'},
        ),
      );
      final ctx = buildTodayContext([item], now: _nowFixture());
      expect(ctx['plan_remaining_count'], 1);
      expect(ctx.containsKey('waiting_on_others_count'), isFalse);
    });
  });

  group('completed=true', () {
    test('never counted in either, regardless of actionability', () {
      final ctx = buildTodayContext([
        _itemWithActionability(id: 'JIRA-6', title: 'Done', actionability: 'self', completed: true),
        _itemWithActionability(id: 'JIRA-7', title: 'Was waiting', actionability: 'waiting', completed: true),
        _itemWithActionability(id: 'JIRA-8', title: 'Was blocked', actionability: 'blocked', completed: true),
        _planItem(id: 'plan-2', title: 'Done plan', completed: true),
      ], now: _nowFixture());
      expect(ctx['plan_remaining_count'], 0);
      expect(ctx.containsKey('waiting_on_others_count'), isFalse);
    });
  });

  group('waiting_on_others_count == 0', () {
    test('field is OMITTED from the returned payload (key not present)', () {
      final ctx = buildTodayContext([
        _itemWithActionability(id: 'JIRA-9', title: 'On plate', actionability: 'self'),
      ], now: _nowFixture());
      expect(
        ctx.containsKey('waiting_on_others_count'),
        isFalse,
        reason: 'Old prompt / payload readers must not see a zero value.',
      );
    });

    test('all-null actionability inputs → key still omitted', () {
      final ctx = buildTodayContext([
        _planItem(id: 'plan-3', title: 'a'),
        _planItem(id: 'plan-4', title: 'b'),
      ], now: _nowFixture());
      expect(ctx.containsKey('waiting_on_others_count'), isFalse);
    });
  });

  group('CRITICAL regression: pre-change snapshot', () {
    test('3 items, all null actionability → payload matches the pre-change shape byte-for-byte', () {
      // Three known items: one overdue plan, one stuck Jira (no actionability),
      // one plain plan with no due date. This is the exact shape today's
      // backend produces before the classifier rolls out — output MUST be
      // identical to the pre-change behavior.
      final now = _nowFixture();
      // NOTE: ExternalSource.daysAtStatus reads DateTime.now() (NOT the test's
      // `now` fixture). Subtract from real now so the asserted age is stable.
      final realNow = DateTime.now();
      final statusChangedAt = realNow.subtract(const Duration(days: 5));
      final expectedAgeInDays = DateTime.now().difference(statusChangedAt).inDays;
      final items = <ActionItem>[
        _planItem(id: 'plan-1', title: 'Plan the week').copyWith(dueAt: now.subtract(const Duration(hours: 14))),
        ActionItem(
          id: 'WPNG-2951',
          description: 'CSV import',
          completed: false,
          externalSource: ExternalSource(
            source: 'jira',
            externalId: 'WPNG-2951',
            url: 'https://x.atlassian.net/browse/WPNG-2951',
            metadata: {'status_changed_at': statusChangedAt.toUtc().toIso8601String()},
          ),
        ),
        _planItem(id: 'plan-2', title: 'Loose plan item'),
      ];

      final ctx = buildTodayContext(items, now: now);

      final overdueDueAt = now.subtract(const Duration(hours: 14)).toUtc().toIso8601String();
      final expected = <String, dynamic>{
        'overdue': [
          {'id': 'plan-1', 'title': 'Plan the week', 'due_at': overdueDueAt, 'source': 'transcript'},
        ],
        'due_soon': <Map<String, dynamic>>[],
        'stuck_jira': [
          {'id': 'WPNG-2951', 'title': 'CSV import', 'age_in_days': expectedAgeInDays, 'source': 'jira'},
        ],
        'plan_remaining_count': 3,
        // NOTE: no waiting_on_others_count key — that's the contract.
      };

      expect(ctx, equals(expected));
      expect(ctx.containsKey('waiting_on_others_count'), isFalse);
    });
  });

  group('Mix scenario from the design test plan', () {
    test('2 self + 3 waiting + 1 blocked + 1 completed → plan_remaining_count=2, waiting_on_others_count=4', () {
      final items = <ActionItem>[
        _itemWithActionability(id: 'S1', title: 'self a', actionability: 'self'),
        _itemWithActionability(id: 'S2', title: 'self b', actionability: 'self'),
        _itemWithActionability(id: 'W1', title: 'waiting a', actionability: 'waiting'),
        _itemWithActionability(id: 'W2', title: 'waiting b', actionability: 'waiting'),
        _itemWithActionability(id: 'W3', title: 'waiting c', actionability: 'waiting'),
        _itemWithActionability(id: 'B1', title: 'blocked a', actionability: 'blocked'),
        _itemWithActionability(id: 'D1', title: 'done a', actionability: 'self', completed: true),
      ];
      final ctx = buildTodayContext(items, now: _nowFixture());
      expect(ctx['plan_remaining_count'], 2);
      expect(ctx['waiting_on_others_count'], 4);
    });
  });

  group('off-plate items excluded from focal-item lists', () {
    test('blocked item with overdue due_at does NOT appear in overdue list', () {
      final now = _nowFixture();
      final yesterday = now.subtract(const Duration(days: 1));
      final items = <ActionItem>[
        ActionItem(
          id: 'B-overdue',
          description: 'blocked + overdue — user said off plate, exclude from focal',
          dueAt: yesterday, completed: false,
          externalSource: ExternalSource(
            source: 'jira',
            externalId: 'B-overdue',
            url: 'https://x.atlassian.net/browse/B-overdue',
            metadata: const {'actionability': 'blocked'},
          ),
        ),
        _itemWithActionability(id: 'S1', title: 'self on plate', actionability: 'self'),
      ];
      final ctx = buildTodayContext(items, now: now);
      expect((ctx['overdue'] as List), isEmpty);
      expect(ctx['plan_remaining_count'], 1); // just S1
      expect(ctx['waiting_on_others_count'], 1); // just B-overdue
    });

    test('waiting item due in 2h does NOT appear in due_soon list', () {
      final now = _nowFixture();
      final inTwoHours = now.add(const Duration(hours: 2));
      final items = <ActionItem>[
        ActionItem(
          id: 'W-soon',
          description: 'waiting + due soon — off plate, exclude from focal',
          dueAt: inTwoHours, completed: false,
          externalSource: ExternalSource(
            source: 'jira',
            externalId: 'W-soon',
            url: 'https://x.atlassian.net/browse/W-soon',
            metadata: const {'actionability': 'waiting'},
          ),
        ),
      ];
      final ctx = buildTodayContext(items, now: now);
      expect((ctx['due_soon'] as List), isEmpty);
      expect(ctx['waiting_on_others_count'], 1);
    });

    test('blocked Jira stuck for 7 days does NOT appear in stuck_jira list', () {
      // ExternalSource.daysAtStatus reads wall-clock DateTime.now() rather
      // than the test's now fixture. Anchor status_changed_at off real now.
      final sevenDaysAgo = DateTime.now().subtract(const Duration(days: 7));
      final items = <ActionItem>[
        ActionItem(
          id: 'B-stuck',
          description: 'blocked + stuck — off plate, exclude from focal',
          completed: false,
          externalSource: ExternalSource(
            source: 'jira',
            externalId: 'B-stuck',
            url: 'https://x.atlassian.net/browse/B-stuck',
            metadata: {
              'actionability': 'blocked',
              'status_changed_at': sevenDaysAgo.toUtc().toIso8601String(),
            },
          ),
        ),
      ];
      final ctx = buildTodayContext(items, now: _nowFixture());
      expect((ctx['stuck_jira'] as List), isEmpty);
      expect(ctx['waiting_on_others_count'], 1);
    });

    test('regression: null actionability + overdue STILL flows into overdue (preserves pre-change behavior)', () {
      final now = _nowFixture();
      final yesterday = now.subtract(const Duration(days: 1));
      final items = <ActionItem>[
        ActionItem(id: 'P-overdue', description: 'plan item overdue', completed: false, dueAt: yesterday),
      ];
      final ctx = buildTodayContext(items, now: now);
      expect((ctx['overdue'] as List).length, 1);
      expect(ctx['plan_remaining_count'], 1);
    });
  });
}
