import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/services/api_client.dart';
import 'package:nooto_v2/services/notification_service.dart';
import 'package:nooto_v2/settings/screens/notifications_settings_screen.dart';

ApiClient _stubApiClient() => ApiClient(
  httpClient: MockClient((_) async => http.Response('{}', 200)),
  getIdToken: ({bool forceRefresh = false}) async => 'tok',
  signOut: () async {},
  baseUrl: 'https://example.test/',
);

Widget _harness({Future<PermissionStatus> Function(Permission)? permissionResolver}) {
  // SharedPreferences in-memory backing for the toggle hydration.
  SharedPreferences.setMockInitialValues(const {});
  final notifications = NotificationService(client: _stubApiClient());
  return MultiProvider(
    providers: [ChangeNotifierProvider<NotificationService>.value(value: notifications)],
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: NotificationsSettingsScreen(permissionResolver: permissionResolver),
    ),
  );
}

void main() {
  testWidgets('renders the Notifications toggle row with description', (tester) async {
    await tester.pumpWidget(_harness(permissionResolver: (_) async => PermissionStatus.granted));
    await tester.pumpAndSettle();

    // Two "Notifications" texts: AppBar title + toggle row label.
    expect(find.text('Notifications'), findsAtLeastNWidgets(1));
    expect(find.byType(Switch), findsOneWidget);

    // Description paragraph from settingsNotificationsDescription.
    expect(find.textContaining('proactive messages to your Inbox'), findsOneWidget);
  });
}
