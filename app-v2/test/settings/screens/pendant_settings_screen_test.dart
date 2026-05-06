import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/audio/codec.dart';
import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/settings/screens/pendant_settings_screen.dart';

import '../../test_helpers/fake_pendant_provider.dart';

Widget _harness({required FakePendantProvider pendant}) {
  return MultiProvider(
    providers: [ChangeNotifierProvider<PendantProvider>.value(value: pendant)],
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const PendantSettingsScreen(),
    ),
  );
}

void main() {
  testWidgets('pendant section renders live PendantInfo values from provider', (tester) async {
    final since = DateTime.utc(2026, 5, 3, 14, 7);
    final pendant = FakePendantProvider(
      initial: PendantInfo(
        state: PendantState.live,
        deviceId: 'AA:BB:CC:DD:EE:FF',
        deviceName: 'My Pendant',
        codec: BleAudioCodec.opus,
        batteryPercent: 73,
        offlineSince: since,
        droppedPacketsLastInterrupt: 4,
      ),
    );

    await tester.pumpWidget(_harness(pendant: pendant));
    await tester.pumpAndSettle();

    expect(find.text('live'), findsOneWidget);
    expect(find.text('My Pendant'), findsOneWidget);
    expect(find.text('opus'), findsOneWidget);
    expect(find.text('73'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);

    // deviceId is truncated head…tail.
    expect(find.text('AA:B…E:FF'), findsOneWidget);

    // offlineSince serializes as ISO-8601.
    expect(find.text(since.toIso8601String()), findsOneWidget);
  });
}
