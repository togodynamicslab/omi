import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/onboarding/onboarding_chat_provider.dart';
import 'package:nooto_v2/onboarding/widgets/pair_pendant_turn.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';

import '../../test_helpers/fake_pendant_provider.dart';

/// Captures method calls without bootstrapping the real onboarding chat.
class _StubOnboardingChatProvider extends OnboardingChatProvider {
  int skipCurrentCalls = 0;
  final List<(String, dynamic)> reportWidgetCaptureCalls = [];

  @override
  Future<void> skipCurrent(BuildContext context) async {
    skipCurrentCalls++;
  }

  @override
  Future<void> reportWidgetCapture(BuildContext context, String widgetTurnId, dynamic capturedValue) async {
    reportWidgetCaptureCalls.add((widgetTurnId, capturedValue));
  }
}

Widget _harness(FakePendantProvider pendant, _StubOnboardingChatProvider chat, {String turnId = 'turn-1'}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<PendantProvider>.value(value: pendant),
      ChangeNotifierProvider<OnboardingChatProvider>.value(value: chat),
    ],
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(child: PairPendantTurn(turnId: turnId)),
      ),
    ),
  );
}

void main() {
  testWidgets('renders prompt + Pair / Skip CTAs in unpaired state', (tester) async {
    final pendant = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    final chat = _StubOnboardingChatProvider();
    await tester.pumpWidget(_harness(pendant, chat));
    await tester.pumpAndSettle();

    expect(find.textContaining("Pair your pendant when you're ready"), findsOneWidget);
    expect(find.text('Pair'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
  });

  testWidgets('Skip calls OnboardingChatProvider.skipCurrent', (tester) async {
    final pendant = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    final chat = _StubOnboardingChatProvider();
    await tester.pumpWidget(_harness(pendant, chat));
    await tester.pumpAndSettle();

    expect(chat.skipCurrentCalls, 0);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(chat.skipCurrentCalls, 1);
  });

  testWidgets('state transition unpaired -> live auto-advances via reportWidgetCapture', (tester) async {
    final pendant = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    final chat = _StubOnboardingChatProvider();
    await tester.pumpWidget(_harness(pendant, chat, turnId: 'turn-42'));
    await tester.pumpAndSettle();

    expect(chat.reportWidgetCaptureCalls, isEmpty);

    pendant.setInfo(const PendantInfo(state: PendantState.live));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(chat.reportWidgetCaptureCalls, hasLength(1));
    expect(chat.reportWidgetCaptureCalls.single, ('turn-42', true));
  });

  testWidgets('auto-advance fires only once even on multiple live notifications', (tester) async {
    final pendant = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    final chat = _StubOnboardingChatProvider();
    await tester.pumpWidget(_harness(pendant, chat));
    await tester.pumpAndSettle();

    pendant.setInfo(const PendantInfo(state: PendantState.live));
    await tester.pumpAndSettle();
    pendant.setInfo(const PendantInfo(state: PendantState.live, batteryPercent: 80));
    await tester.pumpAndSettle();

    expect(chat.reportWidgetCaptureCalls, hasLength(1));
  });
}
