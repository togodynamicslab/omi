import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/settings/settings_screen.dart';
import 'package:nooto_v2/settings/widgets/category_row.dart';

Widget _harness({String? Function()? emailResolver}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: SettingsScreen(emailResolver: emailResolver ?? () => null),
  );
}

void main() {
  testWidgets('renders all six category rows at the top level', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // Each category surfaces as a SettingsCategoryRow with the labelled text.
    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Pendant'), findsOneWidget);
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
    expect(find.text('Developer'), findsOneWidget);

    // 6 SettingsCategoryRow widgets total (one per category).
    expect(find.byType(SettingsCategoryRow), findsNWidgets(6));
  });

  testWidgets('search field filters categories live by query match', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // Pre-filter: 6 rows.
    expect(find.byType(SettingsCategoryRow), findsNWidgets(6));

    // Type a query that should match only Permissions.
    final searchField = find.byType(CupertinoSearchTextField);
    expect(searchField, findsOneWidget);
    await tester.enterText(searchField, 'microphone');
    await tester.pumpAndSettle();

    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Account'), findsNothing);
    expect(find.text('Pendant'), findsNothing);
    expect(find.byType(SettingsCategoryRow), findsOneWidget);
  });

  testWidgets('search empty state appears when no categories match', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final searchField = find.byType(CupertinoSearchTextField);
    await tester.enterText(searchField, 'zzznotacategory');
    await tester.pumpAndSettle();

    expect(find.text('No matching settings'), findsOneWidget);
    expect(find.byType(SettingsCategoryRow), findsNothing);
  });
}
