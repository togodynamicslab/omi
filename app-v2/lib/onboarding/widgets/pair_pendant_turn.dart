import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/onboarding/onboarding_chat_provider.dart';
import 'package:nooto_v2/pendant/pendant_screen.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
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
///   - "Pair"  → pushes `PendantScreen.route()`. When state transitions
///     to `live` and **stays** live for [_liveHoldDuration], auto-advances
///     via `reportWidgetCapture(true)`.
///   - "Skip"  → calls `OnboardingChatProvider.skipCurrent`.
///
/// State changes in `PendantProvider.info` are watched so the turn auto-
/// advances the chat once pairing has stabilized — no extra tap.
///
/// **Why the 1.5s hold (ENG-4):** the pendant magic-moment ceremony plays a
/// 1.5s greeting after first reaching `live`. Auto-advancing the chat
/// immediately on `live` would yank the chat forward "underneath" the
/// greeting. Holding for [_liveHoldDuration] before reporting capture
/// lets the greeting finish, and also rejects spurious flickers (live
/// → reconnecting → live in <1.5s) without falsely advancing.
class PairPendantTurn extends StatefulWidget {
  final String turnId;
  const PairPendantTurn({super.key, required this.turnId});

  @override
  State<PairPendantTurn> createState() => _PairPendantTurnState();
}

class _PairPendantTurnState extends State<PairPendantTurn> {
  /// How long `PendantState.live` must hold continuously before we treat
  /// pairing as "settled" and advance the chat. Matches the greeting hold
  /// in `pendant_screen.dart`.
  static const Duration _liveHoldDuration = Duration(milliseconds: 1500);

  Timer? _captureTimer;
  PendantState? _lastState;
  bool _reported = false;

  /// Idempotent: arms the capture timer the first time we see `live`,
  /// cancels it on any regression away from `live`. Safe to call from
  /// every `build` — no side effects after the timer has already fired.
  void _onStateChange(PendantState newState) {
    if (_reported) return;
    if (newState == PendantState.live) {
      // Arm the timer if not already armed.
      _captureTimer ??= Timer(_liveHoldDuration, () {
        if (!mounted) return;
        _reported = true;
        context.read<OnboardingChatProvider>().reportWidgetCapture(context, widget.turnId, true);
      });
    } else {
      // Regression — cancel the pending capture so a flicker doesn't
      // count as a stable pairing.
      _captureTimer?.cancel();
      _captureTimer = null;
    }
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _captureTimer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final info = context.watch<PendantProvider>().info;

    _onStateChange(info.state);
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
                  onPressed: () => Navigator.of(context).push(PendantScreen.route()),
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
