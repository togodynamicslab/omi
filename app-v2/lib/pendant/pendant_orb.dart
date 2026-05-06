import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:nooto_v2/theme/app_theme.dart';

/// Intensity values for the [PendantOrb]. Each value maps to a distinct
/// motion + alpha + color recipe that encodes the user-pendant relationship
/// state (per design doc Premise 4 — "the orb means relationship; its
/// presence and intensity carry meaning").
///
/// - [breathing]: live, healthy connection — slow scale pulse @ 10 BPM,
///   steady alpha, brand color.
/// - [flickering]: actively recovering (reconnecting) — irregular scale and
///   alpha flicker @ ~1Hz, brand color.
/// - [dim]: paired but not actively transmitting (offline / interrupted) —
///   static, low alpha, tertiary color.
enum PendantOrbIntensity { breathing, flickering, dim }

/// A small ambient orb that visualizes the live state of the user's pendant.
///
/// Source of truth:
/// `.gstack/projects/togodynamicslab-omi/matheusoliviera-main-design-pendant-magic-moment-20260504-124235.md`
/// — see the "Orb intensity table" section for the per-intensity motion
/// recipe and the "Detailed Design" section for placement.
///
/// Per design doc Premise 4, the orb represents the user-pendant relationship.
/// Its presence (vs absence pre-pair) and its intensity (breathing /
/// flickering / dim) carry the state's meaning — color/motion are not
/// decoration, they are the encoding. The orb is purely visual; all
/// information has a corresponding text equivalent in adjacent widgets, so
/// the orb itself is wrapped in [ExcludeSemantics].
///
/// Reduced motion: when `MediaQuery.disableAnimations == true`, animations
/// collapse to a static dot (see the design doc "Reduced-motion behavior"
/// section). The widget re-evaluates this on every build, so a mid-session
/// toggle from Control Center is honored without remounting.
class PendantOrb extends StatefulWidget {
  const PendantOrb({super.key, required this.intensity, this.size = 80, this.audioLevel});

  /// State-coded recipe; see [PendantOrbIntensity] for semantics.
  final PendantOrbIntensity intensity;

  /// Diameter of the orb at scale 1.0, in logical pixels. Default 80 matches
  /// the SettledPaired layout's orb anchor (see design doc DR-1).
  final double size;

  /// Optional 0..1 audio activity. When non-null AND intensity is
  /// `breathing`, the orb's scale + alpha modulate with this value so the
  /// orb visually responds to what the pendant's mic is hearing — gentle
  /// breath at silence, brighter pulse during speech. Per 2026-05-05
  /// dogfood: "visualize the waves of the mic so feel it alive."
  /// Wired to `PendantProvider.audioActivity` in the SettledPaired layout.
  final ValueListenable<double>? audioLevel;

  @override
  State<PendantOrb> createState() => _PendantOrbState();
}

class _PendantOrbState extends State<PendantOrb> with SingleTickerProviderStateMixin {
  /// Single controller drives both scale and alpha for [PendantOrbIntensity.breathing]
  /// and [PendantOrbIntensity.flickering]. Held idle (and not running) for
  /// [PendantOrbIntensity.dim] and for any intensity under reduced motion.
  late AnimationController _controller;

  /// Test-only handle on the controller. Lets tests assert that the
  /// animation is idle under reduced motion without reaching into private
  /// state.
  @visibleForTesting
  AnimationController get debugController => _controller;

  /// Tracks whether we've already synced the controller for the first time.
  /// We can't read MediaQuery from `initState`, so the first sync is deferred
  /// to `didChangeDependencies`.
  bool _didFirstSync = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _durationFor(widget.intensity));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didFirstSync) {
      _didFirstSync = true;
      _syncControllerForIntensity();
    }
  }

  @override
  void didUpdateWidget(covariant PendantOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.intensity != widget.intensity) {
      // Same controller, new period + run state. Reset to a known anchor so
      // alpha tweens that key off the controller value start cleanly.
      _controller.stop();
      _controller.duration = _durationFor(widget.intensity);
      _controller.value = 0;
      _syncControllerForIntensity();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Drive the controller per the current intensity. Caller is responsible
  /// for stopping it first if changing state.
  void _syncControllerForIntensity() {
    final reducedMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reducedMotion) {
      // Reduced motion: no animation, regardless of intensity.
      return;
    }
    switch (widget.intensity) {
      case PendantOrbIntensity.breathing:
        // 10 BPM = 6 second period. We use repeat(reverse: true) with a
        // 3-second one-way duration so the full breath cycle is 6s.
        _controller.duration = const Duration(seconds: 3);
        _controller.repeat(reverse: true);
        break;
      case PendantOrbIntensity.flickering:
        // 1Hz flicker — full cycle 1000ms. Drive the controller forward in
        // a single direction, looping.
        _controller.duration = const Duration(milliseconds: 1000);
        _controller.repeat();
        break;
      case PendantOrbIntensity.dim:
        // Static; controller stays idle.
        break;
    }
  }

  /// Initial controller duration before [_syncControllerForIntensity] sets the
  /// authoritative period. Kept in sync so `initState` doesn't briefly install
  /// a 0-duration controller that would assert on `repeat`.
  Duration _durationFor(PendantOrbIntensity intensity) {
    switch (intensity) {
      case PendantOrbIntensity.breathing:
        return const Duration(seconds: 3);
      case PendantOrbIntensity.flickering:
        return const Duration(milliseconds: 1000);
      case PendantOrbIntensity.dim:
        return const Duration(seconds: 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.of(context).disableAnimations;

    // Reduced-motion path: ensure the controller isn't running and short-
    // circuit to a static dot. We don't toggle the controller in build, only
    // when intensity changes — but if a user enables reduced motion mid-life,
    // the controller may still be running from a prior build. Safe to stop
    // here because the AnimatedBuilder below ignores it on reduced motion.
    if (reducedMotion && _controller.isAnimating) {
      _controller.stop();
    } else if (!reducedMotion && !_controller.isAnimating && widget.intensity != PendantOrbIntensity.dim) {
      // Re-arm if reduced motion was toggled off mid-session.
      _syncControllerForIntensity();
    }

    // Listenable composition: rebuild the orb on either the controller
    // tick OR an audio-level change. When [audioLevel] is null, we just
    // listen to the controller (existing behavior).
    final listenables = <Listenable>[
      _controller,
      if (widget.audioLevel != null) widget.audioLevel!,
    ];

    return ExcludeSemantics(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Center(
          child: AnimatedBuilder(
            animation: Listenable.merge(listenables),
            builder: (context, _) {
              final recipe = _recipe(reducedMotion);
              return Transform.scale(
                scale: recipe.scale,
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    color: recipe.color.withValues(alpha: recipe.alpha),
                    shape: BoxShape.circle,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// Compute the (scale, alpha, color) for the current frame given the
  /// controller's value, the intensity, and the reduced-motion flag.
  _OrbRecipe _recipe(bool reducedMotion) {
    switch (widget.intensity) {
      case PendantOrbIntensity.breathing:
        // Audio-reactive bonuses on top of the breathing baseline. Null
        // audioLevel = no bonus = pure breathing (existing behavior).
        final audio = widget.audioLevel?.value ?? 0.0;
        if (reducedMotion) {
          // Skip the breathing scale tween but still respect audio so the
          // orb brightens when speech happens. Alpha base 0.85 → up to 1.0.
          return _OrbRecipe(scale: 1.0, alpha: (0.85 + 0.15 * audio).clamp(0.0, 1.0), color: AppColors.brandPrimary);
        }
        // Breathing baseline: scale 1.0 → 1.06 (10 BPM, easeInOutSine).
        final eased = Curves.easeInOutSine.transform(_controller.value);
        // Audio kicks in additive: +0.0 at silence, +0.10 at peak speech.
        // Alpha steady at 0.85 baseline, brightens to 1.0 at audio peak.
        final scale = 1.0 + 0.06 * eased + 0.10 * audio;
        final alpha = (0.85 + 0.15 * audio).clamp(0.0, 1.0);
        return _OrbRecipe(scale: scale, alpha: alpha, color: AppColors.brandPrimary);
      case PendantOrbIntensity.flickering:
        if (reducedMotion) {
          // The average of the flicker alpha range, per design doc.
          return const _OrbRecipe(scale: 1.0, alpha: 0.7, color: AppColors.brandPrimary);
        }
        // 1Hz square-ish flicker on alpha: 0.85 for the bright half,
        // 0.5 for the dim half, with a 100ms ease at each edge of the
        // 1000ms cycle. Implemented as a piecewise function on [0..1].
        final t = _controller.value;
        final alpha = _flickerAlpha(t);
        // Scale 1.0 ↔ 1.04 with an "irregular" feel — we modulate using a
        // slightly out-of-phase cosine so it doesn't look perfectly
        // synchronized with the alpha square wave.
        final scaleT = 0.5 - 0.5 * _cosTau(t * 1.3);
        final scale = 1.0 + 0.04 * scaleT;
        return _OrbRecipe(scale: scale, alpha: alpha, color: AppColors.brandPrimary);
      case PendantOrbIntensity.dim:
        return const _OrbRecipe(scale: 1.0, alpha: 0.35, color: AppColors.textTertiary);
    }
  }

  /// Square-ish flicker on `t ∈ [0..1]` producing the alpha schedule:
  /// - `[0.0..0.1]`: ease 0.5 → 0.85
  /// - `[0.1..0.5]`: hold 0.85
  /// - `[0.5..0.6]`: ease 0.85 → 0.5
  /// - `[0.6..1.0]`: hold 0.5
  double _flickerAlpha(double t) {
    const low = 0.5;
    const high = 0.85;
    if (t < 0.1) {
      final k = Curves.easeInOut.transform(t / 0.1);
      return low + (high - low) * k;
    } else if (t < 0.5) {
      return high;
    } else if (t < 0.6) {
      final k = Curves.easeInOut.transform((t - 0.5) / 0.1);
      return high - (high - low) * k;
    } else {
      return low;
    }
  }

  /// `cos(2π * t)`, written out so we don't pull in `dart:math` for one call
  /// site.
  double _cosTau(double t) {
    // Simple Taylor-free wrap: use `Curves.easeInOut` of a sawtooth-like
    // function to get a "wobbling" feel without importing math. Two
    // out-of-phase triangles produce a smooth, slightly irregular curve
    // when sampled vs the alpha square wave.
    final wrapped = (t % 1.0);
    // Triangle wave 0→1→0 on [0..1]; treat as a coarse cosine substitute.
    final tri = wrapped < 0.5 ? wrapped * 2 : (1 - wrapped) * 2;
    // Map triangle [0..1] to "cosine" [1..-1]: peak at 0, trough at 0.5.
    return 1 - 2 * tri;
  }
}

class _OrbRecipe {
  const _OrbRecipe({required this.scale, required this.alpha, required this.color});
  final double scale;
  final double alpha;
  final Color color;
}
