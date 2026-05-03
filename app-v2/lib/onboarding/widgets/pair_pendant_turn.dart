import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/onboarding/onboarding_chat_provider.dart';
import 'package:nooto_v2/providers/pendant_provider_contract.dart';
import 'package:nooto_v2/services/ble/pairing_sheet.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Onboarding chat turn that prompts the user to pair their pendant.
///
/// Sits **after** the speech-profile turn in `chat_step_registry.dart` (per
/// design doc Resolved Decisions: speech profile uses phone mic regardless,
/// pendant pairing is the next turn).
///
/// Mirrors `speech_profile_turn.dart`'s shape — a chrome'd surface card
/// with two CTAs:
///   - "Pair"  → opens `PairingSheet.show(context)`. When state transitions
///     to `live`, auto-advances via `reportWidgetCapture(true)`.
///   - "Skip"  → calls `OnboardingChatProvider.skipCurrent`.
///
/// State changes in `PendantProvider.info` are watched so the turn auto-
/// advances the chat the moment pairing succeeds — no extra tap.
class PairPendantTurn extends StatefulWidget {
  final String turnId;
  const PairPendantTurn({super.key, required this.turnId});

  @override
  State<PairPendantTurn> createState() => _PairPendantTurnState();
}

class _PairPendantTurnState extends State<PairPendantTurn> {
  PendantState? _lastState;
  bool _reported = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final info = context.watch<PendantProvider>().info;

    // Auto-advance the moment we observe the live state. Guarded so we only
    // fire once even if the widget rebuilds.
    if (!_reported && info.state == PendantState.live) {
      _reported = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<OnboardingChatProvider>().reportWidgetCapture(context, widget.turnId, true);
      });
    }
    _lastState = info.state;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppStyles.spacingS),
      padding: const EdgeInsets.all(AppStyles.spacingL),
      decoration: BoxDecoration(
        color: AppColors.backgroundSecondary,
        borderRadius: BorderRadius.circular(AppStyles.radiusXLarge),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.pendantOnboardingTurnText,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: AppStyles.spacingL),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () => PairingSheet.show(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brandPrimary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppStyles.radiusPill)),
                  ),
                  child: const Text('Pair', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: AppStyles.spacingM),
              TextButton(
                onPressed: () => context.read<OnboardingChatProvider>().skipCurrent(context),
                child: const Text(
                  'Skip',
                  style: TextStyle(color: AppColors.textTertiary, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // _lastState is read for state-transition diagnostics in widget tests if
  // ever needed; kept private so the API surface stays minimal.
  // ignore: unused_element
  PendantState? get debugLastState => _lastState;
}
