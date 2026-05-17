import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/home/cards/card_entrance.dart';
import 'package:nooto_v2/home/companion_card.dart';
import 'package:nooto_v2/home/companion_stream_provider.dart';
import 'package:nooto_v2/home/widgets/brief_rich_body.dart';
import 'package:nooto_v2/theme/app_theme.dart';
import 'package:nooto_v2/widgets/synthesized_footer.dart';

/// Synthesized daily brief, voice grammar (no chrome). Sits between the
/// welcome card (priority 1000) and the Today surface card (priority 500),
/// so on a typical Home open the visual flow is:
///
///   ┌ Welcome, Matheus.       (voice, sans-serif bold greeting)
///   ┌ Yesterday you said you'd email John…    (this card, voice)
///   └ Today: ⦁ Email John ⦁ Soccer 8pm        (Today surface card)
///
/// Cached in `home.brief.v1` keyed by local-tz date so a second open the
/// same day doesn't burn another LLM call.
final class MorningBriefCard extends CompanionCard {
  MorningBriefCard({
    required this.dateKey,
    required this.greeting,
    required this.body,
    required this.generatedAt,
  });

  /// Local-timezone YYYY-MM-DD. Same key the cache uses.
  final String dateKey;

  /// One-line opener like "Good morning, Matheus." The card renderer pairs
  /// it with the body. Empty string suppresses the greeting line.
  final String greeting;

  /// Synthesized brief paragraph(s) from the LLM proxy.
  final String body;

  @override
  final DateTime generatedAt;

  @override
  String get id => '$_idPrefix$dateKey';

  @override
  CardKind get kind => CardKind.brief;

  @override
  int get priority => 750;

  @override
  Duration get ttl => const Duration(hours: 24);

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.code,
        'dateKey': dateKey,
        'greeting': greeting,
        'body': body,
        'generatedAt': generatedAt.toIso8601String(),
      };

  factory MorningBriefCard.fromJson(Map<String, dynamic> json) {
    return MorningBriefCard(
      dateKey: json['dateKey'] as String,
      greeting: json['greeting'] as String? ?? '',
      body: json['body'] as String? ?? '',
      generatedAt: DateTime.parse(json['generatedAt'] as String),
    );
  }

  @override
  void onAction(BuildContext context, CardAction action) {
    // Brief is read-only — no inline actions. Tapping does nothing for now;
    // a later pass could open a "remix" / regenerate flow.
  }

  @override
  Widget render(BuildContext context) => _MorningBriefView(card: this);

  static const String _idPrefix = 'brief:';
}

class _MorningBriefView extends StatelessWidget {
  const _MorningBriefView({required this.card});

  final MorningBriefCard card;

  @override
  Widget build(BuildContext context) {
    final hasGreeting = card.greeting.trim().isNotEmpty;
    return CardEntrance(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppStyles.spacingL,
          vertical: AppStyles.spacingM,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasGreeting) ...[
              Text(
                card.greeting,
                style: brandAccent(
                  fontSize: 24,
                  color: AppColors.textPrimary,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: AppStyles.spacingM),
            ],
            BriefRichBody(
              body: card.body,
              style: const TextStyle(
                fontSize: 16,
                color: AppColors.textSecondary,
                // Bumped 1.45 → 1.6 (2026-05-05) — chip-rich prose felt cramped
                // because 24pt-tall chips eat into the leading. 1.6 gives the
                // surrounding text room to breathe around the inline chips.
                height: 1.6,
              ),
            ),
            const SizedBox(height: AppStyles.spacingS),
            _BriefFooter(generatedAt: card.generatedAt),
          ],
        ),
      ),
    );
  }
}

/// Footer for [MorningBriefCard]. Watches `CompanionStreamProvider` only for
/// the `briefInFlight` flag via `Selector` so spinner toggles don't re-run
/// `BriefRichBody`'s tag parser on the body above it. In card unit tests
/// without a provider, falls back to the timestamp-only footer.
class _BriefFooter extends StatelessWidget {
  const _BriefFooter({required this.generatedAt});
  final DateTime generatedAt;

  @override
  Widget build(BuildContext context) {
    return Selector<CompanionStreamProvider?, bool>(
      selector: (_, stream) => stream?.briefInFlight ?? false,
      builder: (context, isRefreshing, _) {
        final stream = context.read<CompanionStreamProvider?>();
        return SynthesizedFooter(
          synthesizedAt: generatedAt,
          onRefresh: stream?.forceRefreshBrief,
          isRefreshing: isRefreshing,
        );
      },
    );
  }
}
