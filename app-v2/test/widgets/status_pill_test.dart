import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/theme/app_theme.dart';
import 'package:nooto_v2/widgets/status_pill.dart';

import '../test_helpers/fake_pendant_provider.dart';

Widget _harness(FakePendantProvider provider, {bool disableAnimations = false}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: ChangeNotifierProvider<PendantProvider>.value(
      value: provider,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          appBar: AppBar(actions: const [StatusPill()]),
          body: const SizedBox.expand(),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('hidden when state == unpaired', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    await tester.pumpWidget(_harness(provider));
    await tester.pump();

    // The widget itself still exists in the tree (StatelessWidget marker),
    // but its body collapses to SizedBox.shrink — no text, no dot.
    expect(find.text('Live'), findsNothing);
    expect(find.text('Connecting…'), findsNothing);
    final pillSize = tester.getSize(find.byType(StatusPill));
    expect(pillSize.width, equals(0));
  });

  testWidgets('renders Live label and pulsing controller when state == live', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.live));
    await tester.pumpWidget(_harness(provider));
    await tester.pump();

    expect(find.text('Live'), findsOneWidget);

    // Active pulse means there's at least one ongoing animation. Pump a
    // small slice and confirm the framework still has scheduled work.
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('renders Connecting label when state == connecting', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.connecting));
    await tester.pumpWidget(_harness(provider));
    await tester.pump();

    expect(find.text('Connecting…'), findsOneWidget);
  });

  testWidgets('renders Reconnecting label when state == reconnecting', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.reconnecting));
    await tester.pumpWidget(_harness(provider));
    await tester.pump();

    expect(find.text('Reconnecting'), findsOneWidget);
  });

  testWidgets('renders Paused label when state == interrupted', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.interrupted));
    await tester.pumpWidget(_harness(provider));
    await tester.pump();

    expect(find.text('Paused'), findsOneWidget);
  });

  testWidgets('renders "Offline since {time}" with formatted time', (tester) async {
    final at1242 = DateTime(2026, 5, 3, 12, 42);
    final provider = FakePendantProvider(
      initial: PendantInfo(state: PendantState.offline, offlineSince: at1242),
    );
    await tester.pumpWidget(_harness(provider));
    await tester.pump();

    expect(find.text('Offline since 12:42'), findsOneWidget);
  });

  testWidgets('reduced motion: state == live renders solid dot, no scheduled animation frame chain', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.live));
    await tester.pumpWidget(_harness(provider, disableAnimations: true));
    await tester.pump();

    expect(find.text('Live'), findsOneWidget);
    // After settling, no animation should be ongoing — disableAnimations
    // suppresses the pulse controller entirely.
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('44pt hit area for tappable states', (tester) async {
    final provider = FakePendantProvider(
      initial: PendantInfo(state: PendantState.offline, offlineSince: DateTime(2026, 5, 3, 12, 42)),
    );
    await tester.pumpWidget(_harness(provider));
    await tester.pump();

    final pillSize = tester.getSize(find.byType(StatusPill));
    expect(pillSize.height, greaterThanOrEqualTo(AppStyles.touchTargetMinimum));
  });

  testWidgets('controller disposed when state transitions live -> reconnecting', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.live));
    await tester.pumpWidget(_harness(provider));
    await tester.pump();

    // Pulse controller is animating: scheduled frame exists.
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.binding.hasScheduledFrame, isTrue);

    provider.setInfo(const PendantInfo(state: PendantState.reconnecting));
    await tester.pump();
    await tester.pumpAndSettle();

    // After leaving live, no animation runs — controller was disposed.
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(find.text('Reconnecting'), findsOneWidget);
  });

  testWidgets('semantics: live state advertises read-only label', (tester) async {
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.live));
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_harness(provider));
    await tester.pump();

    expect(_semanticsContainsLabel(tester, 'Recording active. Pendant connected.'), isTrue);
    handle.dispose();
  });

  testWidgets('semantics: offline state advertises actionable label', (tester) async {
    final provider = FakePendantProvider(
      initial: PendantInfo(state: PendantState.offline, offlineSince: DateTime(2026, 5, 3, 12, 42)),
    );
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_harness(provider));
    await tester.pump();

    expect(_semanticsContainsLabel(tester, 'Pendant offline since 12:42. Double-tap to reconnect.'), isTrue);
    handle.dispose();
  });
}

/// Walk the semantics tree and check whether any node's label contains
/// the expected substring. We use `contains` because `Semantics` + `InkWell`
/// can merge with action hints ("Activate"/"Tap to activate") appended.
bool _semanticsContainsLabel(WidgetTester tester, String expected) {
  final root = tester.binding.rootElement!.findRenderObject()!.debugSemantics;
  if (root == null) return false;
  bool found = false;
  void visit(SemanticsNode node) {
    if (found) return;
    final data = node.getSemanticsData();
    if (data.label.contains(expected)) {
      found = true;
      return;
    }
    node.visitChildren((child) {
      visit(child);
      return !found;
    });
  }

  visit(root);
  return found;
}
