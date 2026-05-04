import 'package:flutter/material.dart';

import 'package:nooto_v2/home/cards/card_entrance.dart';
import 'package:nooto_v2/home/companion_card.dart';
import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/pendant/pendant_screen.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Voice card surfacing pendant pairing on Home.
///
/// Two visible variants by `PendantState` (the design doc's State × surface
/// matrix; Home shows this card only):
///
///   - `unpaired`           — "Connect your pendant" prompt. Priority 950
///                            (between welcome=1000 and brief=750).
///   - `offline` & ≥ 5min   — "Your pendant disconnected at {time}." Priority
///                            600 (above today=500, below brief=750).
///
/// **VOICE CARD per DESIGN.md grammar — no chrome, no border, no fill, no
/// shadow.** Renders direct text on `AppColors.backgroundPrimary`. The widget
/// test enforces this by asserting the absence of any wrapping Container with
/// `backgroundSecondary`.
///
/// Tap → pushes `PendantScreen.route()`. Caller (Home companion stream)
/// gates emission on the `PendantState` predicate above; this card itself
/// does not poke into the provider.
final class ConnectPendantVoiceCard extends CompanionCard {
  ConnectPendantVoiceCard({required this.variant, required this.generatedAt, this.offlineSince});

  /// Which copy + priority to render. Set by the Home wiring based on the
  /// current `PendantState`.
  final ConnectPendantVoiceVariant variant;
  final DateTime? offlineSince;

  @override
  final DateTime generatedAt;

  @override
  String get id => 'pendant.voice.${variant.name}';

  @override
  CardKind get kind => CardKind.welcome; // reuse voice grammar bucket

  @override
  int get priority {
    switch (variant) {
      case ConnectPendantVoiceVariant.unpaired:
        return 950;
      case ConnectPendantVoiceVariant.offlineLatePair:
        return 600;
    }
  }

  /// Card is regenerated each pass from live state, so the TTL only matters
  /// in the unlikely path where Hive holds it past a state change. Short.
  @override
  Duration get ttl => const Duration(hours: 1);

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind.code,
    'variant': variant.name,
    'generatedAt': generatedAt.toIso8601String(),
    if (offlineSince != null) 'offlineSince': offlineSince!.toIso8601String(),
  };

  @override
  void onAction(BuildContext context, CardAction action) {
    if (action == CardAction.tapThrough) {
      Navigator.of(context).push(PendantScreen.route());
    }
  }

  @override
  Widget render(BuildContext context) => _ConnectPendantVoiceCardView(card: this);
}

enum ConnectPendantVoiceVariant { unpaired, offlineLatePair }

/// Picks the voice-card variant for the current pendant state, or null if
/// the card should not be shown. Encapsulates the "≥ 5 min offline" gate
/// from the State × surface matrix so callers don't duplicate it.
ConnectPendantVoiceCard? connectPendantVoiceCardFor(PendantInfo info, {DateTime? now}) {
  final clock = now ?? DateTime.now();
  switch (info.state) {
    case PendantState.unpaired:
      return ConnectPendantVoiceCard(variant: ConnectPendantVoiceVariant.unpaired, generatedAt: clock);
    case PendantState.offline:
      final since = info.offlineSince;
      if (since == null) return null;
      if (clock.difference(since) < const Duration(minutes: 5)) return null;
      return ConnectPendantVoiceCard(
        variant: ConnectPendantVoiceVariant.offlineLatePair,
        generatedAt: clock,
        offlineSince: since,
      );
    case PendantState.permissionDenied:
    case PendantState.pairing:
    case PendantState.connecting:
    case PendantState.incompatible:
    case PendantState.live:
    case PendantState.reconnecting:
    case PendantState.interrupted:
      return null;
  }
}

class _ConnectPendantVoiceCardView extends StatelessWidget {
  const _ConnectPendantVoiceCardView({required this.card});

  final ConnectPendantVoiceCard card;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final (title, body, semantics) = _copyFor(l, card);

    return CardEntrance(
      child: Semantics(
        button: true,
        label: semantics,
        child: InkWell(
          onTap: () => card.onAction(context, CardAction.tapThrough),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL, vertical: AppStyles.spacingM),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: brandEmphasis(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: AppStyles.spacingS),
                Text(body, style: const TextStyle(fontSize: 16, color: AppColors.textSecondary, height: 1.4)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  (String, String, String) _copyFor(AppLocalizations l, ConnectPendantVoiceCard card) {
    switch (card.variant) {
      case ConnectPendantVoiceVariant.unpaired:
        return (
          l.pendantVoiceCardConnectTitle,
          l.pendantVoiceCardConnectBody,
          'Connect your pendant. Double-tap to start pairing.',
        );
      case ConnectPendantVoiceVariant.offlineLatePair:
        final time = _formatTime(card.offlineSince);
        return (
          l.pendantVoiceCardOfflineTitle(time),
          l.pendantVoiceCardOfflineBody,
          'Your pendant disconnected at $time. Double-tap to reconnect.',
        );
    }
  }

  String _formatTime(DateTime? when) {
    if (when == null) return '';
    final h = when.hour.toString().padLeft(2, '0');
    final m = when.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
