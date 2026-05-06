import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/audio/codec.dart';
import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/pendant/pendant_constellation.dart';
import 'package:nooto_v2/pendant/pendant_orb.dart';
import 'package:nooto_v2/pendant/pendant_screen.dart';
import 'package:nooto_v2/pendant/pendant_unpaired_surface_card.dart';
import 'package:nooto_v2/providers/auth_provider.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/providers/pendant_stt_provider.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';

import '../test_helpers/fake_auth_provider.dart';
import '../test_helpers/fake_pendant_provider.dart';

Widget _harness(
  FakePendantProvider provider, {
  Future<bool> Function()? openAppSettings,
  FakeAuthChangeProvider? auth,
}) {
  final authProvider = auth ?? FakeAuthChangeProvider();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<PendantProvider>.value(value: provider),
      ChangeNotifierProvider<AuthChangeProvider>.value(value: authProvider),
      // STT bridge isn't booted in tests — provider stays inactive,
      // liveTranscript stays empty, UI consumers hide cleanly.
      ChangeNotifierProvider<PendantSttProvider>(create: (_) => PendantSttProvider()),
    ],
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PendantScreen(openAppSettings: openAppSettings),
    ),
  );
}

/// Pump enough frames for the constellation widget's continuously-running
/// ticker without falling into `pumpAndSettle`'s timeout (the ceremony
/// animation never settles).
Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  // 8 × 50ms = 400ms — comfortably past the 320ms AnimatedSwitcher cross-fade
  // duration so layout-mode transitions settle before expectations run.
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('Layout-mode mapping', () {
    testWidgets('unpaired (not armed) → settledUnpaired with surface card', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
      await tester.pumpWidget(_harness(provider));
      await tester.pumpAndSettle();

      expect(find.byType(PendantUnpairedSurfaceCard), findsOneWidget);
      expect(find.byType(PendantConstellation), findsNothing);
      expect(find.byType(PendantOrb), findsNothing);
      expect(find.text('Pair pendant'), findsOneWidget);
      expect(find.text('Hold your pendant close.'), findsOneWidget);
    });

    testWidgets('permissionDenied → settledUnpaired with Open Settings CTA', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.permissionDenied));
      await tester.pumpWidget(_harness(provider));
      await tester.pumpAndSettle();

      expect(find.byType(PendantUnpairedSurfaceCard), findsOneWidget);
      expect(find.byType(PendantConstellation), findsNothing);
      expect(find.text('Open Settings'), findsOneWidget);
    });

    testWidgets('incompatible (pre-pair) → settledUnpaired with functional copy', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.incompatible));
      await tester.pumpWidget(_harness(provider));
      await tester.pumpAndSettle();

      expect(find.byType(PendantUnpairedSurfaceCard), findsOneWidget);
      // Pre-pair incompatible keeps existing functional copy (DR-2).
      expect(
        find.text("This pendant doesn't expose the right audio service. Make sure your firmware is up to date."),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('pairing (armed) → takeover with PendantConstellation', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
      await tester.pumpWidget(_harness(provider));
      await tester.pumpAndSettle();

      // Tap Pair to arm + simulate provider transition to pairing.
      await tester.tap(find.text('Pair pendant'));
      await tester.pump();
      provider.setState(PendantState.pairing);
      await _pumpFrames(tester);

      expect(find.byType(PendantConstellation), findsOneWidget);
      expect(find.byType(PendantUnpairedSurfaceCard), findsNothing);
      expect(find.byType(AppBar), findsNothing); // Full-bleed: no AppBar.
    });

    testWidgets('pairing (NOT armed) → settledUnpaired (defensive)', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.pairing));
      await tester.pumpWidget(_harness(provider));
      await _pumpFrames(tester);

      expect(find.byType(PendantConstellation), findsNothing);
      expect(find.byType(PendantUnpairedSurfaceCard), findsOneWidget);
    });

    testWidgets('connecting (armed) → takeover', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
      await tester.pumpWidget(_harness(provider));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pair pendant'));
      await tester.pump();
      provider.setState(PendantState.pairing);
      await _pumpFrames(tester);
      provider.setState(PendantState.connecting);
      await _pumpFrames(tester);

      expect(find.byType(PendantConstellation), findsOneWidget);
    });

    testWidgets('connecting (NOT armed) → settledPaired with flickering orb', (tester) async {
      // The cold offline → reconnect path: arm flag never set.
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.connecting));
      await tester.pumpWidget(_harness(provider));
      await _pumpFrames(tester);

      final orb = tester.widget<PendantOrb>(find.byType(PendantOrb));
      expect(orb.intensity, PendantOrbIntensity.flickering);
      expect(find.byType(PendantConstellation), findsNothing);
      // SettledPaired layout no longer has an AppBar (per 2026-05-05 dogfood
      // restyle); back link lives as a floating TextButton.icon top-left.
      expect(find.byType(AppBar), findsNothing);
    });

    testWidgets('live (NOT armed) → settledPaired with breathing orb + device info', (tester) async {
      final provider = FakePendantProvider(
        initial: const PendantInfo(
          state: PendantState.live,
          deviceName: 'My Pendant',
          codec: BleAudioCodec.opus,
          batteryPercent: 87,
        ),
      );
      await tester.pumpWidget(_harness(provider));
      await _pumpFrames(tester);

      final orb = tester.widget<PendantOrb>(find.byType(PendantOrb));
      expect(orb.intensity, PendantOrbIntensity.breathing);
      expect(find.text('My Pendant'), findsOneWidget);
      expect(find.text('Codec: opus'), findsOneWidget);
      expect(find.text('87% battery'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);
    });

    testWidgets('live with no deviceName falls back to default', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.live));
      await tester.pumpWidget(_harness(provider));
      await _pumpFrames(tester);

      expect(find.text('Nooto pendant'), findsOneWidget);
    });

    testWidgets('reconnecting → settledPaired with flickering orb', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.reconnecting));
      await tester.pumpWidget(_harness(provider));
      await _pumpFrames(tester);

      final orb = tester.widget<PendantOrb>(find.byType(PendantOrb));
      expect(orb.intensity, PendantOrbIntensity.flickering);
      expect(find.text('Reconnecting'), findsOneWidget);
    });

    testWidgets('offline → settledPaired with dim orb + Reconnect CTA', (tester) async {
      final since = DateTime(2026, 5, 3, 14, 7);
      final provider = FakePendantProvider(
        initial: PendantInfo(state: PendantState.offline, offlineSince: since),
      );
      await tester.pumpWidget(_harness(provider));
      await _pumpFrames(tester);

      final orb = tester.widget<PendantOrb>(find.byType(PendantOrb));
      expect(orb.intensity, PendantOrbIntensity.dim);
      expect(find.text('Reconnect'), findsOneWidget);
      expect(find.textContaining('Offline since'), findsOneWidget);
    });

    testWidgets('interrupted → settledPaired with dim orb + paused explainer', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.interrupted));
      await tester.pumpWidget(_harness(provider));
      await _pumpFrames(tester);

      final orb = tester.widget<PendantOrb>(find.byType(PendantOrb));
      expect(orb.intensity, PendantOrbIntensity.dim);
      expect(find.text('Paused while another audio session is active.'), findsOneWidget);
      // No CTA in interrupted state — orb intensity is the activity signal.
      expect(find.text('Reconnect'), findsNothing);
      expect(find.text('Disconnect'), findsNothing);
    });
  });

  group('Pair CTA + arm-clearing (CQ-2)', () {
    testWidgets('Pair pendant tap calls provider.startPair', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
      await tester.pumpWidget(_harness(provider));
      await tester.pumpAndSettle();

      expect(provider.startPairCallCount, 0);
      await tester.tap(find.text('Pair pendant'));
      await tester.pumpAndSettle();
      expect(provider.startPairCallCount, 1);
    });

    testWidgets('arm-clearing: pairing(armed) → permissionDenied flips to settledUnpaired', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
      await tester.pumpWidget(_harness(provider));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pair pendant'));
      await tester.pump();
      provider.setState(PendantState.pairing);
      await _pumpFrames(tester);
      expect(find.byType(PendantConstellation), findsOneWidget);

      provider.setState(PendantState.permissionDenied);
      await _pumpFrames(tester);

      // Arm flag must be cleared — layout flips to settledUnpaired.
      expect(find.byType(PendantConstellation), findsNothing);
      expect(find.byType(PendantUnpairedSurfaceCard), findsOneWidget);
      expect(find.text('Open Settings'), findsOneWidget);
    });

    testWidgets('arm-clearing: connecting(armed) → incompatible shows AI-voiced failure copy', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
      await tester.pumpWidget(_harness(provider));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pair pendant'));
      await tester.pump();
      provider.setState(PendantState.pairing);
      await _pumpFrames(tester);
      provider.setState(PendantState.connecting);
      await _pumpFrames(tester);
      provider.setState(PendantState.incompatible);
      // Wait for the constellation's failure-fade timer (300ms) + the
      // arm-flag clear in the screen.
      await tester.pump(const Duration(milliseconds: 350));

      // Per 2026-05-05 dogfood, the failure overlay lives INSIDE the
      // constellation (particles dim to 30% behind), not on a separate
      // settled-unpaired surface card. The widget stays mounted.
      expect(find.byType(PendantConstellation), findsOneWidget);
      // AI-voiced incompatible failure copy (DR-2) rendered inside the
      // constellation's overlay area.
      expect(
        find.text("This pendant doesn't speak my language. Make sure your firmware is up to date."),
        findsOneWidget,
      );
    });

    testWidgets('arm-clearing: connecting(armed) → unpaired shows BLE error copy', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
      await tester.pumpWidget(_harness(provider));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pair pendant'));
      await tester.pump();
      provider.setState(PendantState.pairing);
      await _pumpFrames(tester);
      provider.setState(PendantState.connecting);
      await _pumpFrames(tester);
      provider.setState(PendantState.unpaired);
      await tester.pump(const Duration(milliseconds: 350));

      // Failure overlay lives inside the constellation now (per 2026-05-05).
      expect(find.byType(PendantConstellation), findsOneWidget);
      expect(find.text("Something interrupted the connection. Let's try once more."), findsOneWidget);
    });

    testWidgets('arm-clearing: pairing(armed) → unpaired shows timeout copy', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
      await tester.pumpWidget(_harness(provider));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pair pendant'));
      await tester.pump();
      provider.setState(PendantState.pairing);
      await _pumpFrames(tester);
      provider.setState(PendantState.unpaired);
      await tester.pump(const Duration(milliseconds: 350));

      // Failure overlay lives inside the constellation now (per 2026-05-05).
      expect(find.byType(PendantConstellation), findsOneWidget);
      expect(find.text("I can't see your pendant from here. Hold it close and let's try again."), findsOneWidget);
    });
  });

  group('Try again after failure', () {
    testWidgets('Try again re-arms ceremony + clears failure kind', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
      await tester.pumpWidget(_harness(provider));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pair pendant'));
      await tester.pump();
      provider.setState(PendantState.pairing);
      await _pumpFrames(tester);
      provider.setState(PendantState.unpaired); // timeout
      await tester.pump(const Duration(milliseconds: 350));

      // Failure surface visible.
      expect(find.text("I can't see your pendant from here. Hold it close and let's try again."), findsOneWidget);

      // Tap Try again.
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(provider.startPairCallCount, 2);

      // Layout snaps back to takeover when provider transitions to pairing.
      provider.setState(PendantState.pairing);
      await _pumpFrames(tester);
      expect(find.byType(PendantConstellation), findsOneWidget);
    });
  });

  group('Settled-paired action callbacks', () {
    testWidgets('live → Disconnect tap calls provider.disconnect', (tester) async {
      final provider = FakePendantProvider(
        initial: const PendantInfo(state: PendantState.live, deviceName: 'My Pendant'),
      );
      await tester.pumpWidget(_harness(provider));
      await _pumpFrames(tester);

      expect(provider.disconnectCallCount, 0);
      await tester.tap(find.text('Disconnect'));
      await tester.pump();
      expect(provider.disconnectCallCount, 1);
    });

    testWidgets('offline → Reconnect tap calls provider.reconnect', (tester) async {
      final provider = FakePendantProvider(
        initial: PendantInfo(state: PendantState.offline, offlineSince: DateTime(2026, 5, 3, 14, 7)),
      );
      await tester.pumpWidget(_harness(provider));
      await _pumpFrames(tester);

      expect(provider.reconnectCallCount, 0);
      await tester.tap(find.text('Reconnect'));
      await tester.pump();
      expect(provider.reconnectCallCount, 1);
    });
  });

  group('Constructor seam', () {
    testWidgets('openAppSettings test seam invoked on permissionDenied tap', (tester) async {
      var settingsOpened = 0;
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.permissionDenied));
      await tester.pumpWidget(
        _harness(
          provider,
          openAppSettings: () async {
            settingsOpened++;
            return true;
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open Settings'));
      await tester.pump();
      expect(settingsOpened, 1);
    });
  });

  group('Greeting personalization', () {
    Future<void> driveToGreeting(WidgetTester tester, FakePendantProvider provider) async {
      await tester.tap(find.text('Pair pendant'));
      await tester.pump();
      provider.setState(PendantState.pairing);
      await _pumpFrames(tester);
      provider.setState(PendantState.connecting);
      // Wait past 0.8s found-hold.
      await tester.pump(const Duration(milliseconds: 850));
      provider.setState(PendantState.live);
      // Wait past 0.8s converge → greeting begins.
      await tester.pump(const Duration(milliseconds: 850));
    }

    testWidgets('greeting renders display name when AuthChangeProvider has one', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
      final auth = FakeAuthChangeProvider(displayName: 'Matheus');
      await tester.pumpWidget(_harness(provider, auth: auth));
      await tester.pumpAndSettle();

      await driveToGreeting(tester, provider);
      expect(find.text('Hello, Matheus.'), findsOneWidget);
    });

    testWidgets('greeting falls back to "Hello." when displayName is null', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
      final auth = FakeAuthChangeProvider(displayName: null);
      await tester.pumpWidget(_harness(provider, auth: auth));
      await tester.pumpAndSettle();

      await driveToGreeting(tester, provider);
      expect(find.text('Hello.'), findsOneWidget);
      expect(find.textContaining('Matheus'), findsNothing);
    });
  });

  group('Common chrome', () {
    testWidgets('settledUnpaired shows Pendant title in AppBar', (tester) async {
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
      await tester.pumpWidget(_harness(provider));
      await tester.pumpAndSettle();

      expect(find.text('Pendant'), findsOneWidget);
    });

    testWidgets('settledPaired exposes a Back text-link (no AppBar after restyle)', (tester) async {
      // Per 2026-05-05 dogfood, SettledPaired matches the takeover layout —
      // no AppBar chrome. The back affordance is a TextButton.icon top-left.
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.live));
      await tester.pumpWidget(_harness(provider));
      await _pumpFrames(tester);

      expect(find.byType(AppBar), findsNothing);
      expect(find.text('Back'), findsOneWidget);
    });
  });
}
