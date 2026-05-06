import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nooto_v2/pendant/pendant_orb.dart';

Widget _harness(PendantOrbIntensity intensity, {bool reducedMotion = false, double size = 80}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: reducedMotion),
    child: MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF0F0F0F),
        body: Center(
          child: PendantOrb(intensity: intensity, size: size),
        ),
      ),
    ),
  );
}

/// Pump a finite slice for stable golden capture without `pumpAndSettle`,
/// which would never return for the breathing/flickering controllers (they
/// loop forever).
Future<void> _pumpFrames(
  WidgetTester tester, {
  int frames = 4,
  Duration slice = const Duration(milliseconds: 16),
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(slice);
  }
}

void main() {
  // ---------------------------------------------------------------------------
  // Golden tests: 5 goldens.
  //
  // Mid-cycle anchors are picked deterministically:
  // - breathing: pump 1500ms (controller halfway through 3s one-way) → peak
  //   scale ≈ 1.06, alpha 0.85.
  // - flickering: pump 300ms (controller at t=0.3 of 1000ms cycle) → in the
  //   "high" hold, alpha 0.85, scale near max.
  // - dim: no animation; one frame is sufficient.
  // ---------------------------------------------------------------------------

  testWidgets('golden: breathing intensity (normal motion)', (tester) async {
    await tester.pumpWidget(_harness(PendantOrbIntensity.breathing));
    // Land at controller t ≈ 0.5 (mid one-way breath, peak scale).
    await tester.pump(const Duration(milliseconds: 1500));
    await _pumpFrames(tester, frames: 1);

    await expectLater(find.byType(PendantOrb), matchesGoldenFile('goldens/pendant_orb_breathing_normal_motion.png'));
  });

  testWidgets('golden: breathing intensity (reduced motion)', (tester) async {
    await tester.pumpWidget(_harness(PendantOrbIntensity.breathing, reducedMotion: true));
    await _pumpFrames(tester, frames: 2);

    await expectLater(find.byType(PendantOrb), matchesGoldenFile('goldens/pendant_orb_breathing_reduced_motion.png'));
  });

  testWidgets('golden: flickering intensity (normal motion)', (tester) async {
    await tester.pumpWidget(_harness(PendantOrbIntensity.flickering));
    // Land at controller t ≈ 0.3 — squarely in the "bright hold" region
    // (alpha 0.85). Picks a stable mid-cycle frame.
    await tester.pump(const Duration(milliseconds: 300));
    await _pumpFrames(tester, frames: 1);

    await expectLater(find.byType(PendantOrb), matchesGoldenFile('goldens/pendant_orb_flickering_normal_motion.png'));
  });

  testWidgets('golden: flickering intensity (reduced motion)', (tester) async {
    await tester.pumpWidget(_harness(PendantOrbIntensity.flickering, reducedMotion: true));
    await _pumpFrames(tester, frames: 2);

    await expectLater(find.byType(PendantOrb), matchesGoldenFile('goldens/pendant_orb_flickering_reduced_motion.png'));
  });

  testWidgets('golden: dim intensity', (tester) async {
    await tester.pumpWidget(_harness(PendantOrbIntensity.dim));
    await _pumpFrames(tester, frames: 2);

    await expectLater(find.byType(PendantOrb), matchesGoldenFile('goldens/pendant_orb_dim.png'));
  });

  // ---------------------------------------------------------------------------
  // Semantics: ExcludeSemantics test.
  // ---------------------------------------------------------------------------

  testWidgets('orb is wrapped in ExcludeSemantics (decorative-only)', (tester) async {
    await tester.pumpWidget(_harness(PendantOrbIntensity.breathing));
    await _pumpFrames(tester, frames: 2);

    // Scaffold itself wraps an ExcludeSemantics around its body — so we
    // search descendant of PendantOrb specifically. Exactly one
    // ExcludeSemantics under the orb subtree.
    final excludeFinder = find.descendant(of: find.byType(PendantOrb), matching: find.byType(ExcludeSemantics));
    expect(excludeFinder, findsOneWidget);
    final excludeWidget = tester.widget<ExcludeSemantics>(excludeFinder);
    expect(excludeWidget.excluding, isTrue);
  });

  // ---------------------------------------------------------------------------
  // Intensity-change test.
  // ---------------------------------------------------------------------------

  testWidgets('intensity change rebuild: breathing → flickering, no exceptions', (tester) async {
    await tester.pumpWidget(_harness(PendantOrbIntensity.breathing));
    await _pumpFrames(tester, frames: 4);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_harness(PendantOrbIntensity.flickering));
    await _pumpFrames(tester, frames: 4);
    expect(tester.takeException(), isNull);

    // And to dim — the static intensity. Verifies the controller-stop
    // branch in didUpdateWidget.
    await tester.pumpWidget(_harness(PendantOrbIntensity.dim));
    await _pumpFrames(tester, frames: 4);
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------------------
  // Disposal test.
  // ---------------------------------------------------------------------------

  testWidgets('mount + unmount disposes cleanly — no leaked controllers', (tester) async {
    await tester.pumpWidget(_harness(PendantOrbIntensity.breathing));
    await _pumpFrames(tester, frames: 4);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);

    // Pump a long slice to surface any lingering ticker.
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------------------
  // Reduced-motion test: the controller is NOT running.
  // ---------------------------------------------------------------------------

  testWidgets('reduced-motion: AnimationController is not animating for breathing', (tester) async {
    await tester.pumpWidget(_harness(PendantOrbIntensity.breathing, reducedMotion: true));
    await _pumpFrames(tester, frames: 4);

    // Reach into the State via the test-only `debugController` getter to
    // assert the controller is idle (no ticker scheduled).
    // ignore: avoid_dynamic_calls
    final dynamicState = tester.state(find.byType(PendantOrb)) as dynamic;
    final AnimationController controller = dynamicState.debugController as AnimationController;
    expect(controller.isAnimating, isFalse);
  });

  testWidgets('reduced-motion: AnimationController is not animating for flickering', (tester) async {
    await tester.pumpWidget(_harness(PendantOrbIntensity.flickering, reducedMotion: true));
    await _pumpFrames(tester, frames: 4);

    // ignore: avoid_dynamic_calls
    final dynamicState = tester.state(find.byType(PendantOrb)) as dynamic;
    final AnimationController controller = dynamicState.debugController as AnimationController;
    expect(controller.isAnimating, isFalse);
  });
}
