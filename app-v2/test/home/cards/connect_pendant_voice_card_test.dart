import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/home/cards/connect_pendant_voice_card.dart';
import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/providers/pendant_provider_contract.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/theme/app_theme.dart';

import '../../test_helpers/fake_pendant_provider.dart';

Widget _harness(ConnectPendantVoiceCard card, FakePendantProvider provider) {
  return ChangeNotifierProvider<PendantProvider>.value(
    value: provider,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(child: Builder(builder: (ctx) => card.render(ctx))),
      ),
    ),
  );
}

void main() {
  group('voice grammar (no chrome)', () {
    testWidgets('unpaired variant has NO Container with backgroundSecondary', (tester) async {
      final card = ConnectPendantVoiceCard(variant: ConnectPendantVoiceVariant.unpaired, generatedAt: DateTime.now());
      final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
      await tester.pumpWidget(_harness(card, provider));
      await tester.pumpAndSettle();

      // Voice cards never wrap in a chromed surface. Walk every Container
      // in the rendered subtree and assert none use the surface fill.
      final containers = tester.widgetList<Container>(find.byType(Container));
      for (final c in containers) {
        final dec = c.decoration;
        if (dec is BoxDecoration) {
          expect(
            dec.color,
            isNot(AppColors.backgroundSecondary),
            reason: 'voice card must not wrap in backgroundSecondary chrome',
          );
        }
        // Direct color (not via decoration) — same rule.
        expect(
          c.color,
          isNot(AppColors.backgroundSecondary),
          reason: 'voice card must not set Container.color = backgroundSecondary',
        );
      }
    });
  });

  testWidgets('unpaired variant renders pendantVoiceCardConnect copy', (tester) async {
    final card = ConnectPendantVoiceCard(variant: ConnectPendantVoiceVariant.unpaired, generatedAt: DateTime.now());
    final provider = FakePendantProvider(initial: const PendantInfo(state: PendantState.unpaired));
    await tester.pumpWidget(_harness(card, provider));
    await tester.pumpAndSettle();

    expect(find.text('Connect your pendant'), findsOneWidget);
    expect(find.text('Tap to pair your Omi pendant.'), findsOneWidget);
  });

  testWidgets('offlineLatePair variant renders formatted time + reconnect copy', (tester) async {
    final at1242 = DateTime(2026, 5, 3, 12, 42);
    final card = ConnectPendantVoiceCard(
      variant: ConnectPendantVoiceVariant.offlineLatePair,
      generatedAt: DateTime.now(),
      offlineSince: at1242,
    );
    final provider = FakePendantProvider(
      initial: PendantInfo(state: PendantState.offline, offlineSince: at1242),
    );
    await tester.pumpWidget(_harness(card, provider));
    await tester.pumpAndSettle();

    expect(find.text('Your pendant disconnected at 12:42.'), findsOneWidget);
    expect(find.text('Tap to reconnect.'), findsOneWidget);
  });

  testWidgets('priority is 950 for unpaired and 600 for offlineLatePair', (tester) async {
    final unpaired = ConnectPendantVoiceCard(variant: ConnectPendantVoiceVariant.unpaired, generatedAt: DateTime.now());
    final offline = ConnectPendantVoiceCard(
      variant: ConnectPendantVoiceVariant.offlineLatePair,
      generatedAt: DateTime.now(),
      offlineSince: DateTime(2026, 5, 3, 12, 42),
    );
    expect(unpaired.priority, 950);
    expect(offline.priority, 600);
  });

  group('connectPendantVoiceCardFor predicate', () {
    test('emits unpaired card when state == unpaired', () {
      final c = connectPendantVoiceCardFor(const PendantInfo(state: PendantState.unpaired));
      expect(c, isNotNull);
      expect(c!.variant, ConnectPendantVoiceVariant.unpaired);
    });

    test('emits offlineLatePair only after 5+ minutes offline', () {
      final now = DateTime(2026, 5, 3, 13, 0);
      final justOffline = connectPendantVoiceCardFor(
        PendantInfo(state: PendantState.offline, offlineSince: now.subtract(const Duration(minutes: 2))),
        now: now,
      );
      expect(justOffline, isNull);

      final stale = connectPendantVoiceCardFor(
        PendantInfo(state: PendantState.offline, offlineSince: now.subtract(const Duration(minutes: 6))),
        now: now,
      );
      expect(stale, isNotNull);
      expect(stale!.variant, ConnectPendantVoiceVariant.offlineLatePair);
    });

    test('emits null for live, reconnecting, connecting, etc.', () {
      for (final s in [
        PendantState.live,
        PendantState.connecting,
        PendantState.reconnecting,
        PendantState.interrupted,
        PendantState.permissionDenied,
        PendantState.pairing,
        PendantState.incompatible,
      ]) {
        expect(connectPendantVoiceCardFor(PendantInfo(state: s)), isNull, reason: 'voice card should not emit for $s');
      }
    });
  });
}
