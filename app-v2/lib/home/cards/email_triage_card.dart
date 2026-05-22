import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/home/cards/card_entrance.dart';
import 'package:nooto_v2/home/companion_stream_provider.dart';
import 'package:nooto_v2/services/email_triage_service.dart';
import 'package:nooto_v2/theme/app_theme.dart';
import 'package:nooto_v2/widgets/synthesized_footer.dart';

/// Inbox-triage voice card. Sits directly below the morning brief on Home.
///
/// Voice grammar — NO chrome, NO border, NO container fill. Direct text on
/// `backgroundPrimary`, same padding rhythm as `MorningBriefCard`. Two voice
/// cards stacked is on-pattern (DESIGN.md): the rejection is stacking SURFACE
/// cards; voice cards are "the assistant speaking" and the brief + triage are
/// two distinct moments of synthesis.
///
/// State lives on [CompanionStreamProvider] (`triage`, `triageInFlight`,
/// `triageError`) — same shape as the brief. The card renders one of four
/// variants depending on state:
///   - result present       → greeting + body (rendered verbatim from agent)
///   - in-flight, no result → "Checking your inbox…" placeholder
///   - error, no result     → "Inbox check failed." line with retry hint
///   - none of the above    → empty (card hides)
///
/// Body text is split on the first `\n\n` so the first paragraph reads as the
/// greeting line (sans-serif bold via `brandEmphasis` — subordinate to the
/// brief's `brandAccent` Source Serif, which is the single allowed serif site
/// per DESIGN.md "one place per screen") and the remainder reads as standard
/// `bodyLarge` prose. Em-dot separators and itemized email lines render fine
/// in the default font.
class EmailTriageCard extends StatelessWidget {
  const EmailTriageCard({super.key});

  // Inline strings (English-only) match the morning brief card's approach.
  // No brief-specific l10n keys exist either, so we follow suit.
  static const String _loadingGreeting = 'Checking your inbox…';
  static const String _errorGreeting = 'Inbox check failed.';
  static const String _errorBody = "Couldn't reach Nooto. Pull to refresh.";
  static const String _genericGreeting = 'Inbox check.';

  @override
  Widget build(BuildContext context) {
    return Selector<CompanionStreamProvider, _TriageViewState>(
      selector: (_, p) =>
          _TriageViewState(triage: p.triage, inFlight: p.triageInFlight, hasError: p.triageError != null),
      builder: (context, state, _) {
        if (state.triage == null && !state.inFlight && !state.hasError) {
          return const SizedBox.shrink();
        }
        return CardEntrance(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL, vertical: AppStyles.spacingM),
            child: _buildBody(context, state),
          ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, _TriageViewState state) {
    final triage = state.triage;
    if (triage != null) {
      final split = _splitAnchor(triage.text);
      return _TriageColumn(
        greeting: split.anchor,
        body: split.body,
        footer: _TriageFooter(generatedAt: triage.synthesizedAt),
      );
    }
    if (state.inFlight) {
      return const _TriageColumn(greeting: _loadingGreeting, body: '');
    }
    // hasError, no triage yet.
    return const _TriageColumn(greeting: _errorGreeting, body: _errorBody, bodyColor: AppColors.textTertiary);
  }

  /// Splits the agent output on the first blank line. The agent emits a single
  /// anchor sentence, a blank line, then the structured body. Defensive: if
  /// no `\n\n` is present (rare — e.g., the "Inbox clear" empty state is one
  /// paragraph), surface the whole text as body under a generic greeting.
  static _AnchorSplit _splitAnchor(String text) {
    final trimmed = text.trim();
    final idx = trimmed.indexOf('\n\n');
    if (idx < 0) {
      return _AnchorSplit(anchor: _genericGreeting, body: trimmed);
    }
    final anchor = trimmed.substring(0, idx).trim();
    final body = trimmed.substring(idx + 2).trim();
    if (anchor.isEmpty) {
      return _AnchorSplit(anchor: _genericGreeting, body: body);
    }
    return _AnchorSplit(anchor: anchor, body: body);
  }
}

class _TriageColumn extends StatelessWidget {
  const _TriageColumn({
    required this.greeting,
    required this.body,
    this.footer,
    this.bodyColor = AppColors.textSecondary,
  });

  final String greeting;
  final String body;
  final Widget? footer;
  final Color bodyColor;

  @override
  Widget build(BuildContext context) {
    final hasGreeting = greeting.trim().isNotEmpty;
    final hasBody = body.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasGreeting) ...[
          Text(
            greeting,
            style: brandEmphasis(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              height: 1.25,
            ),
          ),
          if (hasBody) const SizedBox(height: AppStyles.spacingM),
        ],
        if (hasBody) Text(body, style: TextStyle(fontSize: 16, color: bodyColor, height: 1.6)),
        if (footer != null) ...[const SizedBox(height: AppStyles.spacingS), footer!],
      ],
    );
  }
}

/// Footer for [EmailTriageCard]. Watches `CompanionStreamProvider` only for
/// the `triageInFlight` flag via `Selector` so spinner toggles don't re-run
/// the body text rendering.
class _TriageFooter extends StatelessWidget {
  const _TriageFooter({required this.generatedAt});
  final DateTime generatedAt;

  @override
  Widget build(BuildContext context) {
    return Selector<CompanionStreamProvider?, bool>(
      selector: (_, stream) => stream?.triageInFlight ?? false,
      builder: (context, isRefreshing, _) {
        final stream = context.read<CompanionStreamProvider?>();
        return SynthesizedFooter(
          synthesizedAt: generatedAt,
          onRefresh: stream?.forceRefreshEmailTriage,
          isRefreshing: isRefreshing,
        );
      },
    );
  }
}

@immutable
class _AnchorSplit {
  const _AnchorSplit({required this.anchor, required this.body});
  final String anchor;
  final String body;
}

/// Lightweight value snapshot for the [Selector] — equality on the three
/// fields keeps the card rebuild scope tight.
@immutable
class _TriageViewState {
  const _TriageViewState({required this.triage, required this.inFlight, required this.hasError});

  final EmailTriageResult? triage;
  final bool inFlight;
  final bool hasError;

  @override
  bool operator ==(Object other) {
    return other is _TriageViewState &&
        other.triage == triage &&
        other.inFlight == inFlight &&
        other.hasError == hasError;
  }

  @override
  int get hashCode => Object.hash(triage, inFlight, hasError);
}
