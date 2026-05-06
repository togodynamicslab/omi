import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nooto_v2/pendant/pendant_unpaired_surface_card.dart';

Widget _harness({
  required String message,
  required String primaryCtaLabel,
  required VoidCallback onPrimaryTap,
  String? secondaryCtaLabel,
  VoidCallback? onSecondaryTap,
}) {
  return MaterialApp(
    home: Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: PendantUnpairedSurfaceCard(
          message: message,
          primaryCtaLabel: primaryCtaLabel,
          onPrimaryTap: onPrimaryTap,
          secondaryCtaLabel: secondaryCtaLabel,
          onSecondaryTap: onSecondaryTap,
        ),
      ),
    ),
  );
}

void main() {
  // ---------------------------------------------------------------------------
  // Golden tests
  // ---------------------------------------------------------------------------

  testWidgets('golden: primary CTA only', (tester) async {
    await tester.pumpWidget(
      _harness(message: 'Hold your pendant close.', primaryCtaLabel: 'Pair pendant', onPrimaryTap: () {}),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(PendantUnpairedSurfaceCard),
      matchesGoldenFile('goldens/pendant_unpaired_surface_card_primary_only.png'),
    );
  });

  testWidgets('golden: primary + secondary CTA', (tester) async {
    await tester.pumpWidget(
      _harness(
        message: 'Bluetooth and microphone access are needed to pair.',
        primaryCtaLabel: 'Pair pendant',
        onPrimaryTap: () {},
        secondaryCtaLabel: 'Open Settings',
        onSecondaryTap: () {},
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(PendantUnpairedSurfaceCard),
      matchesGoldenFile('goldens/pendant_unpaired_surface_card_with_secondary.png'),
    );
  });

  // ---------------------------------------------------------------------------
  // Behavior tests
  // ---------------------------------------------------------------------------

  testWidgets('primary tap fires onPrimaryTap callback', (tester) async {
    var primaryTaps = 0;
    await tester.pumpWidget(
      _harness(
        message: 'Hold your pendant close.',
        primaryCtaLabel: 'Pair pendant',
        onPrimaryTap: () => primaryTaps += 1,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Pair pendant'));
    await tester.pumpAndSettle();

    expect(primaryTaps, 1);
  });

  testWidgets('secondary tap fires onSecondaryTap callback', (tester) async {
    var secondaryTaps = 0;
    await tester.pumpWidget(
      _harness(
        message: 'Bluetooth and microphone access are needed to pair.',
        primaryCtaLabel: 'Pair pendant',
        onPrimaryTap: () {},
        secondaryCtaLabel: 'Open Settings',
        onSecondaryTap: () => secondaryTaps += 1,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Open Settings'));
    await tester.pumpAndSettle();

    expect(secondaryTaps, 1);
  });

  testWidgets('no secondary CTA renders when secondaryCtaLabel is null', (tester) async {
    await tester.pumpWidget(
      _harness(message: 'Hold your pendant close.', primaryCtaLabel: 'Pair pendant', onPrimaryTap: () {}),
    );
    await tester.pumpAndSettle();

    // Post-restyle (2026-05-05): primary CTA is now a TextButton (link
    // style), not the prior ElevatedButton pill. With no secondary CTA,
    // we expect exactly one TextButton (the primary).
    expect(find.byType(TextButton), findsOneWidget);
    expect(find.byType(ElevatedButton), findsNothing);
  });

  testWidgets('assertion fires when secondaryCtaLabel is provided without onSecondaryTap', (tester) async {
    expect(
      () => PendantUnpairedSurfaceCard(
        message: 'msg',
        primaryCtaLabel: 'primary',
        onPrimaryTap: () {},
        secondaryCtaLabel: 'Foo',
      ),
      throwsAssertionError,
    );
  });

  // ---------------------------------------------------------------------------
  // 5 variant render tests — one per settled-unpaired layout from the design
  // doc's "File plan" entry for `pendant_unpaired_surface_card.dart`.
  // ---------------------------------------------------------------------------

  testWidgets('variant: unpaired renders message + primary CTA', (tester) async {
    const message = 'Hold your pendant close.';
    const primary = 'Pair pendant';
    await tester.pumpWidget(_harness(message: message, primaryCtaLabel: primary, onPrimaryTap: () {}));
    await tester.pumpAndSettle();

    expect(find.text(message), findsOneWidget);
    expect(find.widgetWithText(TextButton, primary), findsOneWidget);
    expect(find.byType(TextButton), findsOneWidget);
  });

  testWidgets('variant: permissionDenied renders message + primary + secondary CTA', (tester) async {
    const message = 'Bluetooth and microphone access are needed to pair.';
    const primary = 'Pair pendant';
    const secondary = 'Open Settings';
    await tester.pumpWidget(
      _harness(
        message: message,
        primaryCtaLabel: primary,
        onPrimaryTap: () {},
        secondaryCtaLabel: secondary,
        onSecondaryTap: () {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(message), findsOneWidget);
    expect(find.widgetWithText(TextButton, primary), findsOneWidget);
    expect(find.widgetWithText(TextButton, secondary), findsOneWidget);
    expect(find.byType(TextButton), findsNWidgets(2));
  });

  testWidgets('variant: incompatible renders message + primary CTA', (tester) async {
    const message = "This pendant doesn't expose Omi audio.";
    const primary = 'Try again';
    await tester.pumpWidget(_harness(message: message, primaryCtaLabel: primary, onPrimaryTap: () {}));
    await tester.pumpAndSettle();

    expect(find.text(message), findsOneWidget);
    expect(find.widgetWithText(TextButton, primary), findsOneWidget);
    expect(find.byType(TextButton), findsOneWidget);
  });

  testWidgets('variant: ceremonyTimeout renders AI-voiced message + primary CTA', (tester) async {
    const message = "I can't see your pendant from here. Hold it close and let's try again.";
    const primary = 'Try again';
    await tester.pumpWidget(_harness(message: message, primaryCtaLabel: primary, onPrimaryTap: () {}));
    await tester.pumpAndSettle();

    expect(find.text(message), findsOneWidget);
    expect(find.widgetWithText(TextButton, primary), findsOneWidget);
    expect(find.byType(TextButton), findsOneWidget);
  });

  testWidgets('variant: ceremonyBleError renders AI-voiced message + primary CTA', (tester) async {
    const message = "Something interrupted the connection. Let's try once more.";
    const primary = 'Try again';
    await tester.pumpWidget(_harness(message: message, primaryCtaLabel: primary, onPrimaryTap: () {}));
    await tester.pumpAndSettle();

    expect(find.text(message), findsOneWidget);
    expect(find.widgetWithText(TextButton, primary), findsOneWidget);
    expect(find.byType(TextButton), findsOneWidget);
  });
}
