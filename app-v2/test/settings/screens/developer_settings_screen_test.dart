import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/settings/screens/developer_settings_screen.dart';

Widget _harness({Future<bool> Function()? openAppSettings, Future<void> Function(BuildContext)? onResetOnboarding}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: DeveloperSettingsScreen(openAppSettings: openAppSettings, onResetOnboarding: onResetOnboarding),
  );
}

void main() {
  testWidgets('Tap Open iOS Settings calls the injected callback', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var openCount = 0;
    await tester.pumpWidget(
      _harness(
        openAppSettings: () async {
          openCount++;
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Open iOS Settings'), findsOneWidget);
    await tester.tap(find.text('Open iOS Settings'));
    await tester.pump();

    expect(openCount, 1);
  });

  testWidgets('Tap Reset onboarding calls the injected reset handler', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var resetCount = 0;
    await tester.pumpWidget(
      _harness(
        onResetOnboarding: (_) async {
          resetCount++;
        },
      ),
    );
    await tester.pumpAndSettle();

    final reset = find.widgetWithText(OutlinedButton, 'Reset onboarding');
    expect(reset, findsOneWidget);
    await tester.tap(reset);
    await tester.pump();

    expect(resetCount, 1);
  });
}
