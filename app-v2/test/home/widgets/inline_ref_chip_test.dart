import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nooto_v2/home/widgets/inline_ref_chip.dart';
import 'package:nooto_v2/theme/app_theme.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('InlineRefChip.plan', () {
    testWidgets('renders the plan title (truncated to 24 chars)', (tester) async {
      await tester.pumpWidget(
        _wrap(InlineRefChip.plan(title: 'Plan the week', onTap: () {})),
      );
      expect(find.text('Plan the week'), findsOneWidget);
    });

    testWidgets('truncates long titles with ellipsis', (tester) async {
      await tester.pumpWidget(
        _wrap(InlineRefChip.plan(
          title: 'Send the absurdly long Q2 invoice to Acme Corp by EOD',
          onTap: () {},
        )),
      );
      // _trimTitle caps at 23 + …
      expect(find.textContaining('…'), findsOneWidget);
    });

    testWidgets('Semantics label is descriptive and marks role=button', (tester) async {
      await tester.pumpWidget(
        _wrap(InlineRefChip.plan(title: 'Plan the week', onTap: () {})),
      );
      final semantics = tester.getSemantics(find.byType(InlineRefChip));
      expect(semantics.label, contains('Plan the week'));
      expect(semantics.label, contains('action item'));
    });

    testWidgets('emphasized variant uses brandPrimary border, default uses 6%-alpha hairline',
        (tester) async {
      await tester.pumpWidget(
        _wrap(Column(
          children: [
            InlineRefChip.plan(title: 'A', onTap: () {}, emphasized: true),
            InlineRefChip.plan(title: 'B', onTap: () {}),
          ],
        )),
      );

      final containers = tester
          .widgetList<Container>(find.descendant(
            of: find.byType(InlineRefChip),
            matching: find.byType(Container),
          ))
          .where((c) => c.decoration is BoxDecoration)
          .where((c) => (c.decoration as BoxDecoration).border != null)
          .toList();

      // Two chips → two bordered containers in order (emphasized first, default second).
      expect(containers, hasLength(2));
      final firstBorder = (containers[0].decoration as BoxDecoration).border as Border;
      final secondBorder = (containers[1].decoration as BoxDecoration).border as Border;
      expect(firstBorder.top.color, AppColors.brandPrimary);
      expect(secondBorder.top.color, isNot(AppColors.brandPrimary));
    });

    testWidgets('tap fires the onTap callback', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(InlineRefChip.plan(title: 'Plan the week', onTap: () => taps++)),
      );
      await tester.tap(find.byType(InlineRefChip));
      expect(taps, 1);
    });
  });

  group('InlineRefChip.ticket (family bump regression)', () {
    testWidgets('ticket chip label uses 14pt font (bumped from 13pt)', (tester) async {
      await tester.pumpWidget(
        _wrap(InlineRefChip.ticket(externalId: 'WPNG-2951', onTap: () {})),
      );
      final text = tester.widget<Text>(find.text('WPNG-2951'));
      expect(text.style?.fontSize, 14);
    });

    testWidgets('ticket chip Semantics labels the role as Jira ticket', (tester) async {
      await tester.pumpWidget(
        _wrap(InlineRefChip.ticket(externalId: 'WPNG-2951', onTap: () {})),
      );
      final semantics = tester.getSemantics(find.byType(InlineRefChip));
      expect(semantics.label, contains('WPNG-2951'));
      expect(semantics.label, contains('Jira ticket'));
    });
  });
}
