import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/pendant/pendant_screen.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/providers/pendant_stt_provider.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Five-state status pill rendered in the Home tab's AppBar trailing slot.
///
/// Wraps in a 44pt hit area mirroring `app/lib/widgets/header_icon_button.dart`
/// so taps in `unpaired`, `offline`, and `incompatible` push `PendantScreen`.
/// Other states are read-only.
///
/// Visual grammar (per design doc Pill state machine + DESIGN.md tokens):
///
///   - `live`        — `brandPrimary` dot, pulsing 1.6s easeInOut breathe.
///   - `connecting`  — `warningColor` dot, no pulse.
///   - `pairing`     — `warningColor` dot, no pulse (mirror of connecting).
///   - `reconnecting`— `textTertiary` dot, no pulse.
///   - `offline`     — `warningColor` dot, "Offline since {time}" label.
///   - `interrupted` — `textTertiary` dot, "Paused" label, no pulse.
///   - `incompatible`— `errorColor` dot, briefly visible while screen opens.
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

    // When live, the pill doubles as a live-transcription readout. Tapping
    // it routes to the Pendant screen for the full view. The dot keeps the
    // recording-active signal even while the label morphs into "… words".
    final showTranscript = state == PendantState.live;
    final liveTappable = showTranscript || visual.tappable;
    final transcriptStream = showTranscript ? context.watch<PendantSttProvider>().liveTranscript : null;

    return Semantics(
      label: visual.semanticsLabel,
      button: liveTappable,
      container: true,
      child: SizedBox(
        height: AppStyles.touchTargetMinimum,
        child: InkWell(
          onTap: liveTappable ? () => Navigator.of(context).push(PendantScreen.route()) : null,
          customBorder: const StadiumBorder(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingM, vertical: AppStyles.spacingS),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PulsingDot(color: visual.dotColor, controller: _pulseController),
                const SizedBox(width: AppStyles.spacingS),
                if (transcriptStream != null)
                  ValueListenableBuilder<String>(
                    valueListenable: transcriptStream,
                    builder: (context, transcript, _) {
                      final tail = _tailWords(transcript);
                      return _PillLabel(text: tail.isEmpty ? visual.label : tail);
                    },
                  )
                else
                  _PillLabel(text: visual.label),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Show the last 3 words with a leading "…" so the pill fits in the
  /// AppBar without crowding the kebab. 3 words is the largest that still
  /// reads at a glance — anything more turns the header into a teleprompter.
  String _tailWords(String full) {
    final words = full.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '';
    const maxWords = 3;
    final start = words.length > maxWords ? words.length - maxWords : 0;
    final tail = words.sublist(start).join(' ');
    return start > 0 ? '… $tail' : tail;
  }

  _PillVisual _visualFor(PendantState state, PendantInfo info, AppLocalizations l) {
    switch (state) {
      case PendantState.live:
        return _PillVisual(
          dotColor: AppColors.brandPrimary,
          label: l.pendantPillLive,
          // tappable here is for screen-reader semantics fallback; the
          // live-state tap target is wired in build() because it depends
          // on the transcript stream, not the pill visual.
          tappable: true,
          semanticsLabel: 'Recording active. Double-tap to open pendant.',
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
        // permissionDenied is also hidden in the pill (PendantScreen drives
        // the recovery UX); unpaired is filtered above.
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

/// Bounded text used inside the pill. Constrains width so a long
/// transcript can't shove the kebab off-screen, single line, ellipsizes
/// at the end (front-trim already happens upstream via `_tailWords`).
class _PillLabel extends StatelessWidget {
  const _PillLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.textPrimary),
      ),
    );
  }
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
