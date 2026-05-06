import 'package:flutter_test/flutter_test.dart';

import 'package:nooto_v2/home/widgets/brief_inline_parser.dart';

void main() {
  group('parseBriefBody', () {
    test('plain text passes through unchanged', () {
      final segments = parseBriefBody('Yesterday was empty. Today: pick up the partner-aware hooks.');
      expect(segments, hasLength(1));
      final first = segments.single as BriefTextSegment;
      expect(first.value, 'Yesterday was empty. Today: pick up the partner-aware hooks.');
    });

    test('empty input yields no segments', () {
      expect(parseBriefBody(''), isEmpty);
    });

    test('single ticket tag is split out', () {
      final segments = parseBriefBody('Pick up <ticket id="WPNG-3417"/> first.');
      expect(segments, hasLength(3));
      expect((segments[0] as BriefTextSegment).value, 'Pick up ');
      final ref = segments[1] as BriefRefSegment;
      expect(ref.kind, BriefRefKind.ticket);
      expect(ref.id, 'WPNG-3417');
      expect((segments[2] as BriefTextSegment).value, ' first.');
    });

    test('three interleaved tags resolve in order', () {
      final segments = parseBriefBody(
        'After <conversation id="conv-1"/> with <person id="p-2"/>, ship <ticket id="WPNG-9"/>.',
      );
      expect(segments, hasLength(7));
      expect((segments[1] as BriefRefSegment).kind, BriefRefKind.conversation);
      expect((segments[1] as BriefRefSegment).id, 'conv-1');
      expect((segments[3] as BriefRefSegment).kind, BriefRefKind.person);
      expect((segments[3] as BriefRefSegment).id, 'p-2');
      expect((segments[5] as BriefRefSegment).kind, BriefRefKind.ticket);
      expect((segments[5] as BriefRefSegment).id, 'WPNG-9');
    });

    test('plan tag is parsed as BriefRefKind.plan', () {
      final segments = parseBriefBody('Today: <plan id="plan-42"/> is overdue.');
      expect(segments, hasLength(3));
      final ref = segments[1] as BriefRefSegment;
      expect(ref.kind, BriefRefKind.plan);
      expect(ref.id, 'plan-42');
    });

    test('plan tag with title="..." attribute captures both id and title', () {
      final segments = parseBriefBody(
        'Today: <plan id="01JMFV" title="Plan the week"/> overdue.',
      );
      expect(segments, hasLength(3));
      final ref = segments[1] as BriefRefSegment;
      expect(ref.kind, BriefRefKind.plan);
      expect(ref.id, '01JMFV');
      expect(ref.title, 'Plan the week');
    });

    test('ticket tag with title= captures both id and title', () {
      final segments = parseBriefBody(
        'Stuck: <ticket id="WPNG-2951" title="CSV import"/>.',
      );
      final ref = segments.whereType<BriefRefSegment>().first;
      expect(ref.id, 'WPNG-2951');
      expect(ref.title, 'CSV import');
    });

    test('legacy tag without title attribute parses with title=null', () {
      // Briefs cached before the 2026-05-05 schema change have tags without
      // title=. Parser must keep parsing them so renderer can fall back.
      final segments = parseBriefBody('Stuck: <ticket id="WPNG-1"/>.');
      final ref = segments.whereType<BriefRefSegment>().first;
      expect(ref.id, 'WPNG-1');
      expect(ref.title, isNull);
    });

    test('empty title="" treats as null (no fallback content)', () {
      final segments = parseBriefBody('Stuck: <ticket id="WPNG-1" title=""/>.');
      final ref = segments.whereType<BriefRefSegment>().first;
      expect(ref.title, isNull);
    });

    test('all four kinds in one body parse in order (regression)', () {
      // Regression guard: extending the regex to include the new `plan` kind
      // must not break parsing of the original three. Keep this test in place
      // for any future kind additions.
      final segments = parseBriefBody(
        'Today: <plan id="plan-1"/> overdue. Talk to <person id="sarah"/> about '
        '<conversation id="conv-9"/> and ship <ticket id="WPNG-3"/>.',
      );
      final refs = segments.whereType<BriefRefSegment>().toList();
      expect(refs.map((r) => r.kind).toList(), [
        BriefRefKind.plan,
        BriefRefKind.person,
        BriefRefKind.conversation,
        BriefRefKind.ticket,
      ]);
      expect(refs.map((r) => r.id).toList(), ['plan-1', 'sarah', 'conv-9', 'WPNG-3']);
    });

    test('tag with extra whitespace still parses', () {
      final segments = parseBriefBody('Open <ticket   id = "WPNG-3417"  /> now.');
      expect(segments, hasLength(3));
      final ref = segments[1] as BriefRefSegment;
      expect(ref.kind, BriefRefKind.ticket);
      expect(ref.id, 'WPNG-3417');
    });

    test('unknown tag name passes through as plain text', () {
      final segments = parseBriefBody('See <unicorn id="x"/> in the wild.');
      expect(segments, hasLength(1));
      expect((segments.single as BriefTextSegment).value, 'See <unicorn id="x"/> in the wild.');
    });

    test('malformed (unclosed) tag passes through as plain text', () {
      final segments = parseBriefBody('Token <ticket id="WPNG-1" without close lands as text.');
      expect(segments, hasLength(1));
      expect((segments.single as BriefTextSegment).value, 'Token <ticket id="WPNG-1" without close lands as text.');
    });

    test('tag at start of body produces no leading text segment', () {
      final segments = parseBriefBody('<ticket id="A-1"/> kicks the day.');
      expect(segments, hasLength(2));
      expect((segments[0] as BriefRefSegment).id, 'A-1');
      expect((segments[1] as BriefTextSegment).value, ' kicks the day.');
    });

    test('tag at end of body produces no trailing text segment', () {
      final segments = parseBriefBody('Today closes with <ticket id="A-1"/>');
      expect(segments, hasLength(2));
      expect((segments[0] as BriefTextSegment).value, 'Today closes with ');
      expect((segments[1] as BriefRefSegment).id, 'A-1');
    });
  });
}
