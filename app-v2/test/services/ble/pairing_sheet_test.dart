import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/services/ble/pairing_sheet.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';

import '../../test_helpers/fake_pendant_provider.dart';

Widget _harness(FakePendantProvider provider, {Future<bool> Function()? openAppSettings}) {
  return ChangeNotifierProvider<PendantProvider>.value(
    value: provider,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showModalBottomSheet<void>(
                context: ctx,
                builder: (sheetCtx) => PairingSheet(openAppSettings: openAppSettings),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openSheet(WidgetTester tester, {bool settle = true}) async {
  await tester.tap(find.text('open'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // For states whose body contains a CircularProgressIndicator, settle
    // never returns — pump enough frames to let the modal route appear,
    // then return.
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
}

void main() {
  testWidgets('renders title and Pair CTA in unpaired state', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    await tester.pumpWidget(_harness(provider));
    await _openSheet(tester);

    expect(find.text('Pair your pendant'), findsOneWidget);
    expect(find.text('Pair'), findsOneWidget);
  });

  testWidgets('Pair tap calls provider.startPair', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    await tester.pumpWidget(_harness(provider));
    await _openSheet(tester);

    expect(provider.startPairCallCount, 0);
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(provider.startPairCallCount, 1);
  });

  testWidgets('connecting state shows progress + "Setting up your pendant…"', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.connecting));
    await tester.pumpWidget(_harness(provider));
    await _openSheet(tester, settle: false);

    expect(find.text('Setting up your pendant…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('pairing state shows progress + "Setting up your pendant…"', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.pairing));
    await tester.pumpWidget(_harness(provider));
    await _openSheet(tester, settle: false);

    expect(find.text('Setting up your pendant…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
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
    await _openSheet(tester);

    expect(find.text('Bluetooth and microphone access are needed to pair.'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);

    await tester.tap(find.text('Open Settings'));
    await tester.pump();
    expect(settingsOpened, 1);
  });

  testWidgets('incompatible state shows Try again CTA + invokes startPair', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.incompatible));
    await tester.pumpWidget(_harness(provider));
    await _openSheet(tester);

    expect(find.text("This pendant doesn't expose Omi audio. Make sure your firmware is up to date."), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(provider.startPairCallCount, 1);
  });

  testWidgets('drag-to-dismiss closes the sheet', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    await tester.pumpWidget(_harness(provider));
    await _openSheet(tester);

    expect(find.text('Pair your pendant'), findsOneWidget);

    // Tap the modal scrim (outside the sheet) — equivalent to a dismiss
    // in showModalBottomSheet's default behavior.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(find.text('Pair your pendant'), findsNothing);
  });
}
