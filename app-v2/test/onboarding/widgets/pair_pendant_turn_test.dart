import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/onboarding/onboarding_chat_provider.dart';
import 'package:nooto_v2/onboarding/widgets/pair_pendant_turn.dart';
import 'package:nooto_v2/pendant/pendant_screen.dart';
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

  testWidgets('Pair pushes PendantScreen route', (tester) async {
    final pendant = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    final chat = _StubOnboardingChatProvider();
    await tester.pumpWidget(_harness(pendant, chat));
    await tester.pumpAndSettle();

    expect(find.byType(PendantScreen), findsNothing);

    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(find.byType(PendantScreen), findsOneWidget);
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

  testWidgets('state transition unpaired -> live auto-advances via reportWidgetCapture (after 1.5s hold)', (
    tester,
  ) async {
    final pendant = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    final chat = _StubOnboardingChatProvider();
    await tester.pumpWidget(_harness(pendant, chat, turnId: 'turn-42'));
    await tester.pumpAndSettle();

    expect(chat.reportWidgetCaptureCalls, isEmpty);

    pendant.setInfo(const PendantInfo(state: PendantState.live));
    await tester.pump();
    // Hold the 1.5s greeting before the chat is allowed to advance.
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();

    expect(chat.reportWidgetCaptureCalls, hasLength(1));
    expect(chat.reportWidgetCaptureCalls.single, ('turn-42', true));
  });

  testWidgets('auto-advance fires only once even on multiple live notifications', (tester) async {
    final pendant = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    final chat = _StubOnboardingChatProvider();
    await tester.pumpWidget(_harness(pendant, chat));
    await tester.pumpAndSettle();

    pendant.setInfo(const PendantInfo(state: PendantState.live));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    pendant.setInfo(const PendantInfo(state: PendantState.live, batteryPercent: 80));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();

    expect(chat.reportWidgetCaptureCalls, hasLength(1));
  });

  testWidgets('reportWidgetCapture fires only after a continuous 1.5s live hold', (tester) async {
    final pendant = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    final chat = _StubOnboardingChatProvider();
    await tester.pumpWidget(_harness(pendant, chat, turnId: 'hold-turn'));
    await tester.pumpAndSettle();

    pendant.setInfo(const PendantInfo(state: PendantState.live));
    await tester.pump();

    // 1499ms in — must NOT have fired yet.
    await tester.pump(const Duration(milliseconds: 1499));
    expect(chat.reportWidgetCaptureCalls, isEmpty);

    // Cross the 1.5s threshold — the timer should now fire.
    await tester.pump(const Duration(milliseconds: 2));
    expect(chat.reportWidgetCaptureCalls, hasLength(1));
    expect(chat.reportWidgetCaptureCalls.single, ('hold-turn', true));
  });

  testWidgets('regression to non-live before 1.5s cancels pending capture; later live re-arms timer', (tester) async {
    final pendant = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    final chat = _StubOnboardingChatProvider();
    await tester.pumpWidget(_harness(pendant, chat, turnId: 'flicker-turn'));
    await tester.pumpAndSettle();

    // Enter live, get most of the way through the hold.
    pendant.setInfo(const PendantInfo(state: PendantState.live));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(chat.reportWidgetCaptureCalls, isEmpty);

    // Regress before the hold completes — the pending capture must cancel.
    pendant.setInfo(const PendantInfo(state: PendantState.reconnecting));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      chat.reportWidgetCaptureCalls,
      isEmpty,
      reason: 'Regression mid-hold must cancel the pending capture timer.',
    );

    // Re-enter live — the timer should re-arm and fire after another 1.5s.
    pendant.setInfo(const PendantInfo(state: PendantState.live));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(chat.reportWidgetCaptureCalls, hasLength(1));
    expect(chat.reportWidgetCaptureCalls.single, ('flicker-turn', true));
  });

  testWidgets('unmount mid-hold cancels pending capture', (tester) async {
    final pendant = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    final chat = _StubOnboardingChatProvider();
    await tester.pumpWidget(_harness(pendant, chat));
    await tester.pumpAndSettle();

    pendant.setInfo(const PendantInfo(state: PendantState.live));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(chat.reportWidgetCaptureCalls, isEmpty);

    // Unmount the widget mid-hold; the timer must be cancelled in dispose().
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 600));

    expect(chat.reportWidgetCaptureCalls, isEmpty, reason: 'Unmount must cancel the pending capture timer.');
  });

  // REGRESSION: prior to ENG-4, reportWidgetCapture fired immediately on live;
  // ensures new 1.5s hold is preserved.
  testWidgets('REGRESSION: live does NOT immediately fire reportWidgetCapture (ENG-4 1.5s hold)', (tester) async {
    final pendant = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    final chat = _StubOnboardingChatProvider();
    await tester.pumpWidget(_harness(pendant, chat));
    await tester.pumpAndSettle();

    pendant.setInfo(const PendantInfo(state: PendantState.live));

    // Same frame — must NOT have fired.
    await tester.pump();
    expect(
      chat.reportWidgetCaptureCalls,
      isEmpty,
      reason: 'Old behavior fired immediately on live; new behavior must wait 1.5s.',
    );

    // 100ms in — still must NOT have fired.
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      chat.reportWidgetCaptureCalls,
      isEmpty,
      reason: 'Capture must wait the full 1.5s hold; 100ms is not enough.',
    );
  });
}
