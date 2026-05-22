import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/home/cards/connect_pendant_voice_card.dart';
import 'package:nooto_v2/home/cards/email_triage_card.dart';
import 'package:nooto_v2/home/cards/morning_brief_card.dart';
import 'package:nooto_v2/home/companion_card.dart';
import 'package:nooto_v2/home/companion_stream_provider.dart';
import 'package:nooto_v2/home/home_nav.dart';
import 'package:nooto_v2/onboarding/onboarding_chat_provider.dart';
import 'package:nooto_v2/providers/action_items_provider.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/theme/app_theme.dart';
import 'package:nooto_v2/widgets/intent_sheet.dart';

/// The Companion Stream Home — Tab 0 of `ShellScreen`.
///
/// Layout (chat-pattern grammar):
///   ┌─────────────────────────────┐
///   │ Card stream (scrollable)    │
///   │   • voice cards (no chrome) │
///   │   • surface cards (chrome)  │
///   ├─────────────────────────────┤
///   │ Composer pill (docked)      │  <- tap → Chat tab
///   └─────────────────────────────┘
///
/// `CompanionStreamProvider` is screen-scoped — instantiated here, dies on
/// nav-away. Hive boxes are the durable source of truth.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.onSwitchToTab});

  /// Called by the composer pill to navigate from Home to another shell tab
  /// (Chat = 1). The shell owns tab state so we hand it a callback.
  final void Function(int tabIndex) onSwitchToTab;

  @override
  Widget build(BuildContext context) {
    final signals = context.read<OnboardingChatProvider>().signals;
    final actionItems = context.read<ActionItemsProvider>();
    return MultiProvider(
      providers: [
        Provider<HomeNav>.value(value: HomeNav(switchToTab: onSwitchToTab)),
        ChangeNotifierProvider<CompanionStreamProvider>(
          create: (_) => CompanionStreamProvider(signals: signals, actionItems: actionItems),
        ),
      ],
      child: _HomeBody(onSwitchToTab: onSwitchToTab),
    );
  }
}

class _HomeBody extends StatelessWidget {
  const _HomeBody({required this.onSwitchToTab});

  final void Function(int tabIndex) onSwitchToTab;

  @override
  Widget build(BuildContext context) {
    return Consumer<CompanionStreamProvider>(
      builder: (context, stream, _) {
        // Selector keeps the rebuild scope tight: only the PendantInfo
        // affects the merged card list. Avoids editing companion_stream_
        // provider.dart so Lane D stays additive.
        return Selector<PendantProvider, PendantInfo>(
          selector: (_, p) => p.info,
          builder: (context, info, _) {
            final cards = _mergePendantCard(stream.cards, info);
            return Stack(
              children: [
                Column(
                  children: [
                    Expanded(child: _CardList(cards: cards)),
                    _Composer(
                      onTap: () {
                        onSwitchToTab(1); // Chat tab
                      },
                    ),
                  ],
                ),
                // On-device "Ask Nooto" entry point — opens the intent
                // sheet that parses NL via Foundation Models and dispatches
                // to Calendar / Reminders / Shortcuts on iOS 26+. Sits as a
                // 44×44 tap target in the safe-area top-right so it doesn't
                // displace the card stream layout.
                const _AskNootoButton(),
              ],
            );
          },
        );
      },
    );
  }

  /// Inserts the connect-pendant voice card into the stream when
  /// `PendantState` is `unpaired` (priority 950) or `offline` for ≥ 5 min
  /// (priority 600). Pure list operation — keeps the stream provider's
  /// generator pattern untouched while honoring the State × surface matrix.
  List<CompanionCard> _mergePendantCard(List<CompanionCard> base, PendantInfo info) {
    final card = connectPendantVoiceCardFor(info);
    if (card == null) {
      return base.where((c) => c is! ConnectPendantVoiceCard).toList();
    }
    final merged = [...base.where((c) => c is! ConnectPendantVoiceCard), card];
    merged.sort((a, b) => b.priority.compareTo(a.priority));
    return merged;
  }
}

class _CardList extends StatelessWidget {
  const _CardList({required this.cards});

  final List<CompanionCard> cards;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () {
        // Brief + triage refresh run in parallel — they're independent agent
        // calls and serializing would double the user-perceived pull wait.
        final stream = context.read<CompanionStreamProvider>();
        return Future.wait([stream.forceRefreshBrief(), stream.forceRefreshEmailTriage()]);
      },
      color: AppColors.brandPrimary,
      backgroundColor: AppColors.backgroundSecondary,
      child: cards.isEmpty ? const _PullableEmpty() : _PopulatedCardList(cards: cards),
    );
  }
}

/// Populated card list, scrollable with always-on physics so the parent
/// `RefreshIndicator` can capture the pull gesture even when content is
/// shorter than the viewport.
///
/// Brief and triage are independent items in the stream — neither's visibility
/// is gated on the other. The brief sits in the provider-managed `cards` list
/// (with its existing `_isContextEmpty` gate). The triage's visibility is
/// computed here from `CompanionStreamProvider` so an empty triage doesn't
/// leave a phantom separator gap in the ListView: hidden when no fetch has
/// been kicked off yet (`triage == null && !inFlight && !hasError`), shown
/// in every other state.
class _PopulatedCardList extends StatelessWidget {
  const _PopulatedCardList({required this.cards});

  final List<CompanionCard> cards;

  @override
  Widget build(BuildContext context) {
    return Selector<CompanionStreamProvider, bool>(
      selector: (_, p) => !(p.triage == null && !p.triageInFlight && p.triageError == null),
      builder: (context, triageVisible, _) {
        // Flatten into sibling items so brief and triage are NOT nested under
        // a shared Column — each is an independent list slot. Triage slots in
        // right after the brief (if both visible), preserving the two-voice-
        // moment rhythm; if brief is hidden, triage floats to the top.
        // Between brief and triage we want `spacingXL` (the natural rhythm
        // for two distinct voice moments per DESIGN.md). ListView.separated
        // already inserts `spacingL` between every pair of items, so we add a
        // top-pad widget that contributes the remaining `spacingXL - spacingL`
        // visually attached to the triage card.
        final items = <Widget>[];
        var briefSeen = false;
        for (final card in cards) {
          items.add(card.render(context));
          if (card is MorningBriefCard && triageVisible) {
            briefSeen = true;
            items.add(
              const Padding(
                padding: EdgeInsets.only(top: AppStyles.spacingXL - AppStyles.spacingL),
                child: EmailTriageCard(),
              ),
            );
          }
        }
        if (triageVisible && !briefSeen) {
          // Brief absent — surface triage at the top of the stream.
          items.insert(0, const EmailTriageCard());
        }
        return ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            AppStyles.spacingL,
            AppStyles.spacingS,
            AppStyles.spacingL,
            AppStyles.spacingXL,
          ),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(height: AppStyles.spacingL),
          itemBuilder: (context, i) => items[i],
        );
      },
    );
  }
}

/// Empty-state body wrapped in a viewport-sized scrollable so the parent
/// `RefreshIndicator` can capture the pull gesture. Without the min-height
/// constraint a too-short child swallows the drag.
class _PullableEmpty extends StatelessWidget {
  const _PullableEmpty();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: const _QuietEmpty(),
        ),
      ),
    );
  }
}

/// Cold-start empty state. Reached only if the welcome card was already
/// dismissed and no other cards exist (no v2 backend wired yet for action
/// items). Still polite, still in-voice.
class _QuietEmpty extends StatelessWidget {
  const _QuietEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppStyles.spacingXL),
        child: Text(
          "I'm here when you need me.",
          style: brandEmphasis(fontSize: 18, fontWeight: FontWeight.w500, color: AppColors.textTertiary),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

/// Tap-target composer that opens the Chat tab. NOT a real `TextField` —
/// tapping the pill routes to Chat with the input focused, where the real
/// send button lives. We deliberately don't show a send button here: there's
/// nothing to send from Home.
class _Composer extends StatelessWidget {
  const _Composer({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppStyles.spacingL,
          AppStyles.spacingS,
          AppStyles.spacingL,
          AppStyles.spacingS,
        ),
        child: Semantics(
          button: true,
          label: "What's on your mind. Opens chat.",
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: AppColors.backgroundSecondary,
              borderRadius: BorderRadius.circular(AppStyles.radiusXLarge),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL, vertical: AppStyles.spacingM),
            // Use a readOnly TextField (vs. plain Text) so hint metrics —
            // line-height, letter-spacing, baseline — match the Chat tab
            // composer exactly. onTap routes to Chat instead of editing.
            child: IgnorePointer(
              ignoring: false,
              child: TextField(
                readOnly: true,
                showCursor: false,
                onTap: onTap,
                style: const TextStyle(fontSize: 16, color: AppColors.textPrimary),
                decoration: const InputDecoration(
                  hintText: "What's on your mind?",
                  hintStyle: TextStyle(fontSize: 16, color: AppColors.textTertiary),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  isDense: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Ask Nooto" entry point — opens the on-device intent parser sheet.
/// Positioned in the Home screen's top-right safe area as a 44×44 tap
/// target. Apple HIG-compliant touch target; uses brand-blue tint so it
/// reads as an interactive primitive rather than chrome.
class _AskNootoButton extends StatelessWidget {
  const _AskNootoButton();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.paddingOf(context).top + AppStyles.spacingS,
      right: AppStyles.spacingL,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => IntentSheet.show(context),
          borderRadius: BorderRadius.circular(AppStyles.touchTargetMinimum / 2),
          child: Container(
            width: AppStyles.touchTargetMinimum,
            height: AppStyles.touchTargetMinimum,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.brandPrimary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppStyles.touchTargetMinimum / 2),
              border: Border.all(color: AppColors.brandPrimary.withValues(alpha: 0.3)),
            ),
            child: const Icon(Icons.auto_awesome, size: 18, color: AppColors.brandPrimary),
          ),
        ),
      ),
    );
  }
}
