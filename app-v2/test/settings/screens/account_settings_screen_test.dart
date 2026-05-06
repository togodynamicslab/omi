import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/settings/screens/account_settings_screen.dart';

import '../../test_helpers/fake_auth_provider.dart';

Widget _harness({String? email}) {
  return MultiProvider(
    providers: [ChangeNotifierProvider<FakeAuthChangeProvider>.value(value: FakeAuthChangeProvider())],
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AccountSettingsScreen(emailResolver: () => email),
    ),
  );
}

void main() {
  testWidgets('signed-in email renders via override', (tester) async {
    await tester.pumpWidget(_harness(email: 'matheus@togodynamics.com'));
    await tester.pumpAndSettle();

    expect(find.text('Signed in as matheus@togodynamics.com'), findsOneWidget);
  });

  testWidgets('not signed in copy renders when email resolver returns null', (tester) async {
    await tester.pumpWidget(_harness(email: null));
    await tester.pumpAndSettle();

    expect(find.text('Not signed in'), findsOneWidget);
  });

  testWidgets('Sign out button is present', (tester) async {
    await tester.pumpWidget(_harness(email: 'matheus@togodynamics.com'));
    await tester.pumpAndSettle();

    expect(find.text('Sign out'), findsOneWidget);
  });
}
