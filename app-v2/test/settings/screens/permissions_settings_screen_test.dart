import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/settings/screens/permissions_settings_screen.dart';

Widget _harness({
  Future<PermissionStatus> Function(Permission)? permissionResolver,
  Future<bool> Function()? openAppSettings,
}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: PermissionsSettingsScreen(permissionResolver: permissionResolver, openAppSettings: openAppSettings),
  );
}

void main() {
  testWidgets('renders all four permission rows with stubbed status text', (tester) async {
    Future<PermissionStatus> resolver(Permission p) async {
      if (p == Permission.microphone) return PermissionStatus.granted;
      if (p == Permission.bluetooth) return PermissionStatus.denied;
      if (p == Permission.notification) return PermissionStatus.permanentlyDenied;
      if (p == Permission.locationWhenInUse) return PermissionStatus.restricted;
      return PermissionStatus.denied;
    }

    await tester.pumpWidget(_harness(permissionResolver: resolver));
    await tester.pumpAndSettle();

    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('Bluetooth'), findsOneWidget);
    // Two "Notifications" labels: one in the AppBar title, one in the
    // permission row.
    expect(find.text('Notifications'), findsAtLeastNWidgets(1));
    expect(find.text('Location'), findsOneWidget);

    expect(find.text('Granted'), findsOneWidget);
    expect(find.text('Denied'), findsOneWidget);
    expect(find.text('Permanently denied'), findsOneWidget);
    expect(find.text('Restricted'), findsOneWidget);

    // Each row exposes its own Open Settings shortcut button.
    expect(find.text('Open Settings'), findsNWidgets(4));
  });
}
