import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nooto_v2/pendant/pendant_constellation.dart';

const _testCopy = PendantCeremonyCopy(
  searching: 'Searching.',
  found: 'Found you.',
  settingUp: 'Setting up.',
  greeting: 'Hello.',
);

Widget _harness(
  Stream<PendantCeremonySignal> signals, {
  bool reducedMotion = false,
  VoidCallback? onComplete,
  VoidCallback? onFailed,
  PendantCeremonyCopy copy = _testCopy,
}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: reducedMotion, size: const Size(390, 844)),
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 390,
          height: 844,
          child: PendantConstellation(
            signals: signals,
            copy: copy,
            onCeremonyComplete: onComplete ?? () {},
            onCeremonyFailed: onFailed ?? () {},
          ),
        ),
      ),
    ),
  );
}

/// Settle the widget by pumping a finite number of frames + small slices —
/// the constellation's ticker drives an infinite animation, so
/// `pumpAndSettle` would never return. We pump explicit frames instead.
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
  // Capture haptic platform calls.
  final hapticCalls = <MethodCall>[];

  setUp(() {
    hapticCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          hapticCalls.add(call);
        }
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  // ---------------------------------------------------------------------------
  // Golden tests: 4 phases × 2 motion modes = 8 goldens.
  // ---------------------------------------------------------------------------

  for (final reducedMotion in [false, true]) {
    final modeSuffix = reducedMotion ? 'reduced_motion' : 'normal_motion';

    testWidgets('golden: drift phase ($modeSuffix)', (tester) async {
      final controller = StreamController<PendantCeremonySignal>.broadcast();
      addTearDown(controller.close);
      await tester.pumpWidget(_harness(controller.stream, reducedMotion: reducedMotion));
      controller.add(PendantCeremonySignal.pairingStarted);
      await _pumpFrames(tester, frames: 6);

      await expectLater(
        find.byType(PendantConstellation),
        matchesGoldenFile('goldens/pendant_constellation_drift_$modeSuffix.png'),
      );
    });

    testWidgets('golden: found phase ($modeSuffix)', (tester) async {
      final controller = StreamController<PendantCeremonySignal>.broadcast();
      addTearDown(controller.close);
      await tester.pumpWidget(_harness(controller.stream, reducedMotion: reducedMotion));
      controller.add(PendantCeremonySignal.pairingStarted);
      await _pumpFrames(tester, frames: 4);
      controller.add(PendantCeremonySignal.connectingEntered);
      // Enough for alpha tween (200ms) to complete.
      await tester.pump(const Duration(milliseconds: 250));
      await _pumpFrames(tester, frames: 2);

      await expectLater(
        find.byType(PendantConstellation),
        matchesGoldenFile('goldens/pendant_constellation_found_$modeSuffix.png'),
      );
    });

    testWidgets('golden: converge phase ($modeSuffix)', (tester) async {
      final controller = StreamController<PendantCeremonySignal>.broadcast();
      addTearDown(controller.close);
      await tester.pumpWidget(_harness(controller.stream, reducedMotion: reducedMotion));
      controller.add(PendantCeremonySignal.pairingStarted);
      await _pumpFrames(tester, frames: 4);
      controller.add(PendantCeremonySignal.connectingEntered);
      // Wait for the 800ms found-hold to elapse → enters converge.
      await tester.pump(const Duration(milliseconds: 850));
      // Then sample mid-converge.
      await tester.pump(const Duration(milliseconds: 400));
      await _pumpFrames(tester, frames: 2);

      await expectLater(
        find.byType(PendantConstellation),
        matchesGoldenFile('goldens/pendant_constellation_converge_$modeSuffix.png'),
      );
    });

    testWidgets('golden: greeting phase ($modeSuffix)', (tester) async {
      final controller = StreamController<PendantCeremonySignal>.broadcast();
      addTearDown(controller.close);
      await tester.pumpWidget(_harness(controller.stream, reducedMotion: reducedMotion));
      controller.add(PendantCeremonySignal.pairingStarted);
      await _pumpFrames(tester, frames: 4);
      controller.add(PendantCeremonySignal.connectingEntered);
      await tester.pump(const Duration(milliseconds: 850));
      // Now in converge; emit liveEntered. After 800ms converge, greeting begins.
      controller.add(PendantCeremonySignal.liveEntered);
      await tester.pump(const Duration(milliseconds: 850));
      // Sample mid-greeting (orb has bloomed).
      await tester.pump(const Duration(milliseconds: 500));
      await _pumpFrames(tester, frames: 2);

      await expectLater(
        find.byType(PendantConstellation),
        matchesGoldenFile('goldens/pendant_constellation_greeting_$modeSuffix.png'),
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Signal-driven behavior tests.
  // ---------------------------------------------------------------------------

  testWidgets('pairingStarted signal shows Searching copy', (tester) async {
    final controller = StreamController<PendantCeremonySignal>.broadcast();
    addTearDown(controller.close);
    await tester.pumpWidget(_harness(controller.stream));
    controller.add(PendantCeremonySignal.pairingStarted);
    await _pumpFrames(tester, frames: 4);

    expect(find.text('Searching.'), findsOneWidget);
  });

  testWidgets('connectingEntered signal advances to Found copy', (tester) async {
    final controller = StreamController<PendantCeremonySignal>.broadcast();
    addTearDown(controller.close);
    await tester.pumpWidget(_harness(controller.stream));
    controller.add(PendantCeremonySignal.pairingStarted);
    await _pumpFrames(tester, frames: 4);
    controller.add(PendantCeremonySignal.connectingEntered);
    await _pumpFrames(tester, frames: 4);

    expect(find.text('Found you.'), findsOneWidget);
  });

  testWidgets('found phase advances to converge after 0.8s when no liveEntered queued', (tester) async {
    final controller = StreamController<PendantCeremonySignal>.broadcast();
    addTearDown(controller.close);
    await tester.pumpWidget(_harness(controller.stream));
    controller.add(PendantCeremonySignal.pairingStarted);
    await _pumpFrames(tester, frames: 4);
    controller.add(PendantCeremonySignal.connectingEntered);
    await _pumpFrames(tester, frames: 2);
    expect(find.text('Found you.'), findsOneWidget);

    // Wait past the 0.8s minimum hold.
    await tester.pump(const Duration(milliseconds: 850));
    expect(find.text('Setting up.'), findsOneWidget);
  });

  testWidgets('greeting copy is rendered from constructor parameter', (tester) async {
    final controller = StreamController<PendantCeremonySignal>.broadcast();
    addTearDown(controller.close);
    await tester.pumpWidget(
      _harness(
        controller.stream,
        copy: const PendantCeremonyCopy(
          searching: 'Searching.',
          found: 'Found you.',
          settingUp: 'Setting up.',
          greeting: 'Hello, Matheus.',
        ),
      ),
    );
    controller.add(PendantCeremonySignal.pairingStarted);
    await _pumpFrames(tester, frames: 2);
    controller.add(PendantCeremonySignal.connectingEntered);
    // Wait past the 0.8s found-hold to enter converge.
    await tester.pump(const Duration(milliseconds: 850));
    controller.add(PendantCeremonySignal.liveEntered);
    // Wait past the 0.8s converge tween to enter greeting.
    await tester.pump(const Duration(milliseconds: 850));
    expect(find.text('Hello, Matheus.'), findsOneWidget);
  });

  testWidgets('liveEntered after converge tween elapses → greeting', (tester) async {
    final controller = StreamController<PendantCeremonySignal>.broadcast();
    addTearDown(controller.close);
    await tester.pumpWidget(_harness(controller.stream));
    controller.add(PendantCeremonySignal.pairingStarted);
    await _pumpFrames(tester, frames: 4);
    controller.add(PendantCeremonySignal.connectingEntered);
    await tester.pump(const Duration(milliseconds: 850));
    // Now in converge.
    controller.add(PendantCeremonySignal.liveEntered);
    // Wait for converge (800ms) to elapse.
    await tester.pump(const Duration(milliseconds: 850));
    expect(find.text('Hello.'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // Found-hold queue test.
  // ---------------------------------------------------------------------------

  testWidgets('liveEntered during 0.8s found-hold buffers; advances on hold elapse', (tester) async {
    final controller = StreamController<PendantCeremonySignal>.broadcast();
    addTearDown(controller.close);
    await tester.pumpWidget(_harness(controller.stream));
    controller.add(PendantCeremonySignal.pairingStarted);
    await _pumpFrames(tester, frames: 4);
    controller.add(PendantCeremonySignal.connectingEntered);
    // 400ms in — still in found-hold.
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Found you.'), findsOneWidget);

    // Live arrives early — gets buffered.
    controller.add(PendantCeremonySignal.liveEntered);
    await _pumpFrames(tester, frames: 2);
    // Should NOT have advanced yet — must wait for 0.8s minimum.
    expect(find.text('Hello.'), findsNothing);
    expect(find.text('Found you.'), findsOneWidget);

    // Pump past the 0.8s mark — should now jump straight to greeting.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Hello.'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // Haptic test.
  // ---------------------------------------------------------------------------

  testWidgets('HapticFeedback.selectionClick fires once on found phase entry', (tester) async {
    final controller = StreamController<PendantCeremonySignal>.broadcast();
    addTearDown(controller.close);
    await tester.pumpWidget(_harness(controller.stream));
    controller.add(PendantCeremonySignal.pairingStarted);
    await _pumpFrames(tester, frames: 4);
    expect(hapticCalls, isEmpty);

    controller.add(PendantCeremonySignal.connectingEntered);
    await _pumpFrames(tester, frames: 4);

    expect(hapticCalls.length, 1);
    expect(hapticCalls.first.method, 'HapticFeedback.vibrate');
    expect(hapticCalls.first.arguments, 'HapticFeedbackType.selectionClick');
  });

  // ---------------------------------------------------------------------------
  // Disposal test.
  // ---------------------------------------------------------------------------

  testWidgets('clean disposal mid-ceremony — no exceptions, no leaked timers', (tester) async {
    final controller = StreamController<PendantCeremonySignal>.broadcast();
    addTearDown(controller.close);
    await tester.pumpWidget(_harness(controller.stream));
    controller.add(PendantCeremonySignal.pairingStarted);
    await _pumpFrames(tester, frames: 4);
    controller.add(PendantCeremonySignal.connectingEntered);
    await tester.pump(const Duration(milliseconds: 200));

    // Unmount mid-found-hold.
    await tester.pumpWidget(const SizedBox.shrink());
    // No scheduled-frame check (the broadcast stream itself isn't tied to
    // the widget). Just verify clean unmount via the absence of exceptions.
    expect(tester.takeException(), isNull);

    // Pump past the 800ms timer to verify it doesn't fire post-unmount.
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------------------
  // onCeremonyComplete callback test.
  // ---------------------------------------------------------------------------

  testWidgets('onCeremonyComplete fires 1.5s after greeting begins (full success path)', (tester) async {
    final controller = StreamController<PendantCeremonySignal>.broadcast();
    addTearDown(controller.close);
    var completedCount = 0;
    await tester.pumpWidget(_harness(controller.stream, onComplete: () => completedCount++));
    controller.add(PendantCeremonySignal.pairingStarted);
    await _pumpFrames(tester, frames: 4);
    controller.add(PendantCeremonySignal.connectingEntered);
    // Pump exactly past the 0.8s found-hold so we enter converge.
    await tester.pump(const Duration(milliseconds: 800));
    await _pumpFrames(tester, frames: 1);
    // Live arrives → buffered for converge end.
    controller.add(PendantCeremonySignal.liveEntered);
    // Pump past 800ms converge → greeting begins.
    await tester.pump(const Duration(milliseconds: 800));
    await _pumpFrames(tester, frames: 1);
    expect(find.text('Hello.'), findsOneWidget);
    expect(completedCount, 0);

    // Pump 1.4s — should still not have fired (greeting holds 1.5s).
    await tester.pump(const Duration(milliseconds: 1400));
    expect(completedCount, 0);

    // Pump past the 1.5s greeting hold.
    await tester.pump(const Duration(milliseconds: 200));
    expect(completedCount, 1);
  });

  // ---------------------------------------------------------------------------
  // onCeremonyFailed callback test.
  // ---------------------------------------------------------------------------

  testWidgets('onCeremonyFailed fires 300ms after failed signal', (tester) async {
    final controller = StreamController<PendantCeremonySignal>.broadcast();
    addTearDown(controller.close);
    var failedCount = 0;
    await tester.pumpWidget(_harness(controller.stream, onFailed: () => failedCount++));
    controller.add(PendantCeremonySignal.pairingStarted);
    await _pumpFrames(tester, frames: 4);

    controller.add(PendantCeremonySignal.failed);
    await _pumpFrames(tester, frames: 2);
    expect(failedCount, 0);

    await tester.pump(const Duration(milliseconds: 200));
    expect(failedCount, 0);

    await tester.pump(const Duration(milliseconds: 150));
    expect(failedCount, 1);
  });
}
