import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/providers/pendant_provider_contract.dart';
import 'package:nooto_v2/services/ble/pairing_sheet.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Five-state status pill rendered in the Home tab's AppBar trailing slot.
///
/// Wraps in a 44pt hit area mirroring `app/lib/widgets/header_icon_button.dart`
/// so taps in `unpaired`, `offline`, and `incompatible` open the pairing
/// sheet. Other states are read-only.
///
/// Visual grammar (per design doc Pill state machine + DESIGN.md tokens):
///
///   - `live`        — `brandPrimary` dot, pulsing 1.6s easeInOut breathe.
///   - `connecting`  — `warningColor` dot, no pulse.
///   - `pairing`     — `warningColor` dot, no pulse (mirror of connecting).
///   - `reconnecting`— `textTertiary` dot, no pulse.
///   - `offline`     — `warningColor` dot, "Offline since {time}" label.
///   - `interrupted` — `textTertiary` dot, "Paused" label, no pulse.
///   - `incompatible`— `errorColor` dot, briefly visible while sheet opens.
///   - `unpaired`    — hidden (`SizedBox.shrink()`).
///
/// Reduced motion: when `MediaQuery.of(context).disableAnimations` is true,
/// the `live` state renders a solid `brandPrimary` dot without a pulse — no
/// AnimationController is created. The controller is only spun up while
/// state == `live` and is disposed on every other transition.
class StatusPill extends StatefulWidget {
  const StatusPill({super.key});

  @override
  State<StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<StatusPill> with SingleTickerProviderStateMixin {
  static const Duration _pulseCycle = Duration(milliseconds: 1600);

  AnimationController? _pulseController;
  PendantState? _lastState;

  void _ensureControllerFor(PendantState state, {required bool reduceMotion}) {
    final shouldPulse = state == PendantState.live && !reduceMotion;
    if (shouldPulse) {
      _pulseController ??= AnimationController(vsync: this, duration: _pulseCycle)..repeat(reverse: true);
    } else if (_pulseController != null) {
      _pulseController!.dispose();
      _pulseController = null;
    }
  }

  @override
  void dispose() {
    _pulseController?.dispose();
    _pulseController = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = context.watch<PendantProvider>().info;
    final state = info.state;
    final reduceMotion = MediaQuery.of(context).disableAnimations;

    if (state != _lastState) {
      _ensureControllerFor(state, reduceMotion: reduceMotion);
      _lastState = state;
    } else {
      // disableAnimations can flip without a state change — keep the
      // controller in sync with the latest accessibility setting.
      _ensureControllerFor(state, reduceMotion: reduceMotion);
    }

    if (state == PendantState.unpaired) {
      return const SizedBox.shrink();
    }

    final l = AppLocalizations.of(context);
    final visual = _visualFor(state, info, l);

    return Semantics(
      label: visual.semanticsLabel,
      button: visual.tappable,
      container: true,
      child: SizedBox(
        height: AppStyles.touchTargetMinimum,
        child: InkWell(
          onTap: visual.tappable ? () => PairingSheet.show(context) : null,
          customBorder: const StadiumBorder(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingM, vertical: AppStyles.spacingS),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PulsingDot(color: visual.dotColor, controller: _pulseController),
                const SizedBox(width: AppStyles.spacingS),
                Text(
                  visual.label,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  _PillVisual _visualFor(PendantState state, PendantInfo info, AppLocalizations l) {
    switch (state) {
      case PendantState.live:
        return _PillVisual(
          dotColor: AppColors.brandPrimary,
          label: l.pendantPillLive,
          tappable: false,
          semanticsLabel: 'Recording active. Pendant connected.',
        );
      case PendantState.connecting:
      case PendantState.pairing:
        return _PillVisual(
          dotColor: AppColors.warningColor,
          label: l.pendantPillConnecting,
          tappable: false,
          semanticsLabel: 'Connecting to pendant.',
        );
      case PendantState.reconnecting:
        return _PillVisual(
          dotColor: AppColors.textTertiary,
          label: l.pendantPillReconnecting,
          tappable: false,
          semanticsLabel: 'Reconnecting to pendant.',
        );
      case PendantState.offline:
        final timeLabel = _formatTime(info.offlineSince);
        return _PillVisual(
          dotColor: AppColors.warningColor,
          label: l.pendantPillOfflineSince(timeLabel),
          tappable: true,
          semanticsLabel: 'Pendant offline since $timeLabel. Double-tap to reconnect.',
        );
      case PendantState.interrupted:
        return _PillVisual(
          dotColor: AppColors.textTertiary,
          label: l.pendantPillPaused,
          tappable: false,
          semanticsLabel: 'Recording paused. Pendant still connected.',
        );
      case PendantState.incompatible:
        return _PillVisual(
          dotColor: AppColors.errorColor,
          label: l.pendantPillConnecting,
          tappable: true,
          semanticsLabel: 'Pendant incompatible. Double-tap to retry pairing.',
        );
      case PendantState.permissionDenied:
      case PendantState.unpaired:
        // permissionDenied is also hidden in the pill (sheet drives the
        // recovery UX); unpaired is filtered above.
        return _PillVisual(dotColor: AppColors.textTertiary, label: '', tappable: false, semanticsLabel: '');
    }
  }

  String _formatTime(DateTime? when) {
    if (when == null) return '';
    final h = when.hour.toString().padLeft(2, '0');
    final m = when.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class _PillVisual {
  const _PillVisual({
    required this.dotColor,
    required this.label,
    required this.tappable,
    required this.semanticsLabel,
  });

  final Color dotColor;
  final String label;
  final bool tappable;
  final String semanticsLabel;
}

class _PulsingDot extends StatelessWidget {
  const _PulsingDot({required this.color, required this.controller});

  final Color color;
  final AnimationController? controller;

  static const double _size = 8.0;

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    final ctrl = controller;
    if (ctrl == null) return dot;
    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, _) {
        // 0.6 → 1.0 → 0.6 breathe via reverse-repeat; CurvedAnimation gives
        // the ease-in/ease-out feel without per-frame math.
        final eased = Curves.easeInOut.transform(ctrl.value);
        final opacity = 0.6 + 0.4 * eased;
        return Opacity(opacity: opacity, child: dot);
      },
    );
  }
}
