import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nooto_v2/audio/codec.dart';
import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/services/api_client.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/services/notification_service.dart';
import 'package:nooto_v2/settings/settings_screen.dart';

import '../test_helpers/fake_pendant_provider.dart';

ApiClient _stubApiClient() => ApiClient(
      httpClient: MockClient((_) async => http.Response('{}', 200)),
      getIdToken: ({bool forceRefresh = false}) async => 'tok',
      signOut: () async {},
      baseUrl: 'https://example.test/',
    );

Widget _harness({
  required FakePendantProvider pendant,
  Future<PermissionStatus> Function(Permission)? permissionResolver,
  Future<bool> Function()? openAppSettings,
  String? Function()? emailResolver,
  Future<void> Function(BuildContext)? onResetOnboarding,
}) {
  // SharedPreferences in-memory backing for the NotificationsCard toggle
  // hydration. Tests that pump this harness don't trigger FCM I/O — they
  // just read the toggle value once on first frame.
  SharedPreferences.setMockInitialValues(const {});
  final notifications = NotificationService(client: _stubApiClient());
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<PendantProvider>.value(value: pendant),
      ChangeNotifierProvider<NotificationService>.value(value: notifications),
    ],
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SettingsScreen(
        permissionResolver: permissionResolver,
        openAppSettings: openAppSettings,
        emailResolver: emailResolver ?? () => null,
        onResetOnboarding: onResetOnboarding,
      ),
    ),
  );
}

void main() {
  testWidgets('renders all four permission rows with stubbed status text', (tester) async {
    final pendant = FakePendantProvider(initial: const PendantInfo.unpaired());

    Future<PermissionStatus> resolver(Permission p) async {
      if (p == Permission.microphone) return PermissionStatus.granted;
      if (p == Permission.bluetooth) return PermissionStatus.denied;
      if (p == Permission.notification) return PermissionStatus.permanentlyDenied;
      if (p == Permission.locationWhenInUse) return PermissionStatus.restricted;
      return PermissionStatus.denied;
    }

    await tester.pumpWidget(_harness(pendant: pendant, permissionResolver: resolver));
    await tester.pumpAndSettle();

    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('Bluetooth'), findsOneWidget);
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Location'), findsOneWidget);

    expect(find.text('Granted'), findsOneWidget);
    expect(find.text('Denied'), findsOneWidget);
    expect(find.text('Permanently denied'), findsOneWidget);
    expect(find.text('Restricted'), findsOneWidget);

    // Each row exposes its own Open Settings shortcut button.
    expect(find.text('Open Settings'), findsNWidgets(4));
  });

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

    await tester.pumpWidget(_harness(pendant: pendant, permissionResolver: (_) async => PermissionStatus.granted));
    await tester.pumpAndSettle();

    // state, deviceName, codec, battery, dropped packets all surface as
    // labeled key/value rows on the dev-mode card.
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

  testWidgets('signed-in email renders via override', (tester) async {
    final pendant = FakePendantProvider(initial: const PendantInfo.unpaired());

    await tester.pumpWidget(
      _harness(
        pendant: pendant,
        permissionResolver: (_) async => PermissionStatus.granted,
        emailResolver: () => 'matheus@togodynamics.com',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Signed in as matheus@togodynamics.com'), findsOneWidget);
  });

  testWidgets('Tap Open iOS Settings calls the injected callback', (tester) async {
    // Tall surface so the actions card lays out without needing scroll.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var openCount = 0;
    final pendant = FakePendantProvider(initial: const PendantInfo.unpaired());

    await tester.pumpWidget(
      _harness(
        pendant: pendant,
        permissionResolver: (_) async => PermissionStatus.granted,
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
    final pendant = FakePendantProvider(initial: const PendantInfo.unpaired());

    await tester.pumpWidget(
      _harness(
        pendant: pendant,
        permissionResolver: (_) async => PermissionStatus.granted,
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
