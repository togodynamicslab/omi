import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/audio/codec.dart';
import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/pendant/pendant_screen.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';

import '../test_helpers/fake_pendant_provider.dart';

Widget _harness(FakePendantProvider provider, {Future<bool> Function()? openAppSettings}) {
  return ChangeNotifierProvider<PendantProvider>.value(
    value: provider,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PendantScreen(openAppSettings: openAppSettings),
    ),
  );
}

void main() {
  testWidgets('unpaired state shows Pair pendant CTA + hint', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    await tester.pumpWidget(_harness(provider));
    await tester.pumpAndSettle();

    expect(find.text('Pendant'), findsOneWidget);
    expect(find.text('Pair pendant'), findsOneWidget);
    expect(find.text('Hold your pendant near your phone.'), findsOneWidget);
  });

  testWidgets('Pair pendant tap calls provider.startPair', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    await tester.pumpWidget(_harness(provider));
    await tester.pumpAndSettle();

    expect(provider.startPairCallCount, 0);
    await tester.tap(find.text('Pair pendant'));
    await tester.pumpAndSettle();

    expect(provider.startPairCallCount, 1);
  });

  testWidgets('permissionDenied state shows Open Settings CTA + invokes opener', (tester) async {
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

    expect(find.text('Bluetooth and microphone access are needed to pair.'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);

    await tester.tap(find.text('Open Settings'));
    await tester.pump();
    expect(settingsOpened, 1);
  });

  testWidgets('pairing state shows progress + setup copy', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.pairing));
    await tester.pumpWidget(_harness(provider));
    // CircularProgressIndicator never settles — pump enough frames for the
    // route to render.
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Setting up your pendant…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('connecting state shows progress + setup copy', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.connecting));
    await tester.pumpWidget(_harness(provider));
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Setting up your pendant…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('incompatible state shows Try again CTA + invokes startPair', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.incompatible));
    await tester.pumpWidget(_harness(provider));
    await tester.pumpAndSettle();

    expect(find.text("This pendant doesn't expose the right audio service. Make sure your firmware is up to date."), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(provider.startPairCallCount, 1);
  });

  testWidgets('live state shows Connected header + device name + codec + battery', (tester) async {
    final provider = FakePendantProvider(
      initial: const PendantInfo(
        state: PendantState.live,
        deviceName: 'My Pendant',
        codec: BleAudioCodec.opus,
        batteryPercent: 87,
      ),
    );
    await tester.pumpWidget(_harness(provider));
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('My Pendant'), findsOneWidget);
    expect(find.text('Codec: opus'), findsOneWidget);
    expect(find.text('87% battery'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
  });

  testWidgets('live state without device name falls back to default', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.live));
    await tester.pumpWidget(_harness(provider));
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Nooto pendant'), findsOneWidget);
  });

  testWidgets('reconnecting state shows spinner + Reconnecting label', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.reconnecting));
    await tester.pumpWidget(_harness(provider));
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Reconnecting'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('offline state shows Reconnect CTA + invokes reconnect', (tester) async {
    final since = DateTime(2026, 5, 3, 14, 7);
    final provider = FakePendantProvider(
      initial: PendantInfo(state: PendantState.offline, offlineSince: since),
    );
    await tester.pumpWidget(_harness(provider));
    await tester.pumpAndSettle();

    expect(find.textContaining('Offline since'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);

    await tester.tap(find.text('Reconnect'));
    await tester.pumpAndSettle();
    expect(provider.reconnectCallCount, 1);
  });

  testWidgets('interrupted state shows Paused + explanation, no CTA', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.interrupted));
    await tester.pumpWidget(_harness(provider));
    await tester.pumpAndSettle();

    expect(find.text('Paused'), findsOneWidget);
    expect(
      find.text('Recording is paused while a phone call or other audio session is active.'),
      findsOneWidget,
    );
    // No Reconnect / Disconnect / Pair pendant buttons in interrupted state.
    expect(find.text('Reconnect'), findsNothing);
    expect(find.text('Disconnect'), findsNothing);
    expect(find.text('Pair pendant'), findsNothing);
  });
}
