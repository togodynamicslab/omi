import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:nooto_v2/theme/app_theme.dart';

/// Localized text rendered during the ceremony beats. Built by the parent
/// (PendantScreen) from l10n + auth provider so the widget itself stays
/// l10n-agnostic and easy to test.
class PendantCeremonyCopy {
  const PendantCeremonyCopy({
    required this.searching,
    required this.found,
    required this.settingUp,
    required this.greeting,
  });

  /// Drift phase: "Searching." (or l10n equivalent)
  final String searching;

  /// Found phase: "Found you."
  final String found;

  /// Converge phase: "Setting up."
  final String settingUp;

  /// Greeting phase: "Hello, {name}." or "Hello." when name is absent.
  /// Already interpolated by the caller — no more substitution happens here.
  final String greeting;
}

/// Deterministic seed for the particle RNG.
///
/// Per the design doc's "Resolved Decisions" section, every "randomized once"
/// particle property uses `Random(seed: 42)` so golden tests are stable. The
/// seed is a constant — not configurable — and the user experience is
/// unchanged because humans don't notice a repeated drift pattern across
/// 3-second visits separated by months.
const int _kParticleSeed = 42;

/// Number of particles in the constellation. Evolved through dogfood:
/// 6 → 18 → 42 → 1000 → 30000 → 5000 (2026-05-05: "Add also 30x more
/// particles" then "too much particles" — 5K is the dialed-back density that
/// stays Apple-Watch-nebula-dense without overwhelming the canvas or the
/// 60fps frame budget on iPhone 16 Pro under Impeller).
const int _kParticleCount = 5000;

/// How many of the closest-to-center particles get brightened during the
/// Found phase. At 1-of-1000 a single brightened particle is invisible; at
/// `_kFoundClusterSize`-of-1000 the brightening reads as "the AI focused on
/// a region of the field." Small enough to still feel like a recognition
/// moment, not a global pulse.
const int _kFoundClusterSize = 12;

/// Radius multiplier applied to brightened particles during Found and
/// Converge phases. Tweens from 1.0x → this value during Found alongside
/// the alpha tween; held through Converge; fades out with everyone else
/// at Greeting.
const double _kFoundRadiusMultiplier = 2.0;

/// Color palette for particles. Apple Watch–style pairing nebulas have
/// stars in slight color variation rather than monochromatic. Stays inside
/// the brand by anchoring on brand-blue + brand-light + soft white — no
/// purple/red/green that would violate DESIGN.md's "one expressive accent."
/// Each particle picks one color at init (deterministic via RNG seed).
const List<Color> _kParticleColors = <Color>[
  Color(0xFF3B82F6), // AppColors.brandPrimary
  Color(0xFF93C5FD), // AppColors.brandLight (DESIGN.md "reserved" — used here)
  Color(0xFFE5E5E5), // AppColors.textSecondary (soft white for star variety)
];

/// Signals emitted by `PendantScreen` to drive the constellation ceremony.
///
/// The widget translates these signals into internal `_CeremonyPhase`
/// transitions. Per the ENG-3 review finding, the widget owns the entire
/// ceremony state machine; the parent is signal-only.
enum PendantCeremonySignal {
  /// User tapped the "Pair pendant" CTA. Enter the `drift` phase.
  pairingStarted,

  /// BLE state advanced to `connecting`. Enter the `found` phase.
  connectingEntered,

  /// BLE state advanced to `live`. Enter the `greeting` phase (after the
  /// minimum found-hold and converge tween have elapsed).
  liveEntered,

  /// Ceremony failed (timeout / BLE error / incompatible flip). Fade
  /// particles out 300ms, then call `onCeremonyFailed`.
  failed,
}

/// Internal phases of the constellation ceremony.
///
/// `drift` → particles drift in confined area while assistant says
/// "Searching."
/// `found` → particles freeze, closest particle to center brightens,
/// assistant says "Found you."
/// `converge` → particles accelerate inward, assistant says "Setting up."
/// `greeting` → particles fade, brand-blue orb pulses once, assistant says
/// "Hello."
enum _CeremonyPhase { drift, found, converge, greeting }

/// Constellation convergence ceremony — the brand moment of meeting your
/// pendant for the first time.
///
/// Source of truth:
/// `.gstack/projects/togodynamicslab-omi/matheusoliviera-main-design-pendant-magic-moment-20260504-124235.md`
/// — see "Detailed Design" → "File plan" + "Ceremony timing".
///
/// ## Constellation signal flow
///
/// ```
///   PendantScreen (BLE state observer)
///         │
///         │ Stream<PendantCeremonySignal>
///         ▼
///   PendantConstellation
///         │
///         ├── pairingStarted   ──► _CeremonyPhase.drift
///         ├── connectingEntered ──► _CeremonyPhase.found  (haptic + 0.8s hold)
///         │                            │
///         │                            └── (0.8s elapses) ──► converge
///         │                                                       │
///         ├── liveEntered (during hold) ──► queue in _pendingPhaseAdvance
///         ├── liveEntered (after hold)  ──► _CeremonyPhase.greeting
///         │                                  │
///         │                                  └── 1.5s ──► onCeremonyComplete()
///         │
///         └── failed ──► fade 300ms ──► onCeremonyFailed()
/// ```
///
/// The widget owns the ceremony state machine, particle physics, found-hold
/// queue, and timing. The parent emits signals on BLE state transitions; the
/// widget translates signals → phases → motion.
class PendantConstellation extends StatefulWidget {
  const PendantConstellation({
    super.key,
    required this.signals,
    required this.copy,
    required this.onCeremonyComplete,
    required this.onCeremonyFailed,
    this.failureMessage,
    this.tryAgainLabel,
    this.onRetry,
    this.backLabel,
    this.onBack,
  }) : assert(
         (failureMessage == null) == (onRetry == null),
         'failureMessage and onRetry must be both null or both non-null',
       );

  /// Stream of signals from the parent. The widget subscribes on init and
  /// cancels on dispose.
  final Stream<PendantCeremonySignal> signals;

  /// Localized ceremony beat copy. Built by the parent so this widget stays
  /// l10n-agnostic (and trivial to golden-test with English strings).
  final PendantCeremonyCopy copy;

  /// Called 1.5s after the `liveEntered` signal — once the greeting beat
  /// has played its full hold.
  final VoidCallback onCeremonyComplete;

  /// Called 300ms after the `failed` signal — once the particles have
  /// faded to the dimmed-ambient state. The screen uses this to flip into
  /// failure-overlay mode (passing `failureMessage` / `onRetry` back into
  /// this same widget instance), NOT to unmount the widget — particles stay
  /// drifting at 30% alpha as ambient backdrop.
  final VoidCallback onCeremonyFailed;

  /// Failure overlay copy — when non-null AND the widget is in the failed
  /// phase, replaces the phase-copy text with this message and renders a
  /// "Try again" button below. Per dogfood 2026-05-05, the try-again UX
  /// lives INSIDE the constellation, not on a separate screen.
  final String? failureMessage;

  /// Label for the "Try again" button rendered alongside [failureMessage].
  /// Defaults to "Try again" if null. Only relevant when [failureMessage]
  /// is non-null.
  final String? tryAgainLabel;

  /// Tap handler for the "Try again" button. The screen typically clears
  /// its failure-overlay flag, re-arms the ceremony, and signals
  /// `pairingStarted` to restart the drift phase. Required when
  /// [failureMessage] is non-null (asserted in the constructor).
  final VoidCallback? onRetry;

  /// Optional secondary back / dismiss text-link rendered below the Try
  /// Again button on the failure overlay. Typically wired to
  /// `Navigator.maybePop(context)` so the user can leave the screen
  /// without tapping Try Again. Defaults to "Back" if [backLabel] is null.
  final String? backLabel;

  /// Tap handler for the back link. When null AND [failureMessage] is set,
  /// no back link is rendered.
  final VoidCallback? onBack;

  @override
  State<PendantConstellation> createState() => _PendantConstellationState();
}

class _PendantConstellationState extends State<PendantConstellation> with SingleTickerProviderStateMixin {
  // Signal subscription.
  StreamSubscription<PendantCeremonySignal>? _signalSub;

  // The single ticker driving particle physics. We use one
  // `AnimationController` and integrate per-frame off `addListener`; this
  // keeps everything on a single `vsync` and avoids juggling controllers.
  late final AnimationController _ticker;
  Duration _lastTick = Duration.zero;

  // Ceremony state.
  _CeremonyPhase _phase = _CeremonyPhase.drift;

  /// Buffers a `liveEntered` signal that arrives during the 0.8s minimum
  /// found-hold. Drained when the hold elapses.
  PendantCeremonySignal? _pendingPhaseAdvance;

  // Timers we own — every one cancelled in dispose().
  Timer? _foundHoldTimer;
  Timer? _convergeTimer;
  Timer? _greetingTimer;
  Timer? _failedTimer;

  // Particles (instantiated once at ceremony start; positions/velocities
  // mutate over time).
  final List<_Particle> _particles = <_Particle>[];

  // Index of the particle that gets brightened in the `found` phase. -1 until
  // entering `found`.
  /// Indices of particles brightened during the Found phase. At
  /// `_kFoundClusterSize` particles, the recognition reads as "the AI focused
  /// on a region" rather than "one star lit up" — necessary at 1000-particle
  /// density. Empty outside the Found / Converge phases.
  final Set<int> _foundParticleIndices = <int>{};

  // Phase-progress tween anchors, in ticker-elapsed microseconds. Using the
  // ticker (not `DateTime.now()`) keeps time monotonic and deterministic for
  // golden tests — `tester.pump(Duration)` advances the ticker by exactly
  // that amount.
  int? _foundAlphaStartUs;
  int? _convergeStartUs;
  int? _greetingStartUs;
  int? _failedStartUs;
  int _nowUs = 0;

  // Lazy canvas size — captured on first build, used by particle physics.
  Size _canvasSize = Size.zero;

  // Whether reduced motion is active for the current frame; checked at every
  // phase boundary per the design doc.
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController.unbounded(vsync: this)..addListener(_onTick);
    _ticker.value = 0;
    _ticker.animateTo(double.infinity, duration: const Duration(days: 1));

    _signalSub = widget.signals.listen(_handleSignal);
    _initParticles();
  }

  @override
  void dispose() {
    _signalSub?.cancel();
    _foundHoldTimer?.cancel();
    _convergeTimer?.cancel();
    _greetingTimer?.cancel();
    _failedTimer?.cancel();
    _ticker
      ..removeListener(_onTick)
      ..stop()
      ..dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Particle init
  // ---------------------------------------------------------------------------

  void _initParticles() {
    final rng = math.Random(_kParticleSeed);
    _particles.clear();
    for (var i = 0; i < _kParticleCount; i++) {
      // Polar-distributed within a unit disk centered at (0.5, 0.5) with
      // radius 0.5. Using sqrt(uniform) for the radial coordinate gives a
      // uniform-area distribution (otherwise particles cluster at center).
      // The painter scales (0..1) × (0..1) to confinedSide pixels, so the
      // disk visually inscribes the existing confined square.
      final theta = rng.nextDouble() * 2 * math.pi;
      final r = math.sqrt(rng.nextDouble()) * 0.5;
      final px = 0.5 + r * math.cos(theta);
      final py = 0.5 + r * math.sin(theta);

      final speed = 8.0 + rng.nextDouble() * 10.0; // 8..18 pt/s
      final dirAngle = rng.nextDouble() * 2 * math.pi;

      // Star-field radius: 0.5..3.5pt, biased small via squared distribution
      // (most stars are tiny dots; a few are noticeably bigger).
      final radiusU = rng.nextDouble();
      final radius = 0.5 + radiusU * radiusU * 3.0;

      // Wider alpha range than before (0.2..0.9) so the field has visual
      // depth — bright foreground stars and dim background ones.
      final alpha = 0.2 + rng.nextDouble() * 0.7;

      // One color picked from the palette per particle.
      final color = _kParticleColors[rng.nextInt(_kParticleColors.length)];

      _particles.add(
        _Particle(
          rng: rng,
          position: Offset(px, py),
          velocity: Offset(math.cos(dirAngle) * speed, math.sin(dirAngle) * speed),
          baseRadius: radius,
          baseAlpha: alpha,
          baseColor: color,
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Signal handling
  // ---------------------------------------------------------------------------

  void _handleSignal(PendantCeremonySignal signal) {
    if (!mounted) return;
    switch (signal) {
      case PendantCeremonySignal.pairingStarted:
        _enterDrift();
        break;
      case PendantCeremonySignal.connectingEntered:
        _enterFound();
        break;
      case PendantCeremonySignal.liveEntered:
        _onLiveEntered();
        break;
      case PendantCeremonySignal.failed:
        _enterFailed();
        break;
    }
  }

  void _enterDrift() {
    _refreshReducedMotion();
    _syncNowUs();
    setState(() {
      _phase = _CeremonyPhase.drift;
      _foundParticleIndices.clear();
      _pendingPhaseAdvance = null;
      _foundAlphaStartUs = null;
      _convergeStartUs = null;
      _greetingStartUs = null;
      _failedStartUs = null;
    });
  }

  void _enterFound() {
    _refreshReducedMotion();
    _syncNowUs();
    // Fire selection-click haptic exactly once on entering the found phase.
    HapticFeedback.selectionClick();

    // Pick the `_kFoundClusterSize` particles closest to canvas center
    // (deterministic for tests via stable seed + sorted-by-distance, ties
    // broken by lowest index). These all brighten together.
    final center = _confinedCenter();
    final indexed = <(int, double)>[];
    for (var i = 0; i < _particles.length; i++) {
      final p = _resolvePixelPosition(_particles[i].position);
      final d = (p - center).distanceSquared;
      indexed.add((i, d));
    }
    indexed.sort((a, b) {
      final c = a.$2.compareTo(b.$2);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    final cluster = <int>{
      for (var k = 0; k < _kFoundClusterSize && k < indexed.length; k++) indexed[k].$1,
    };

    setState(() {
      _phase = _CeremonyPhase.found;
      _foundParticleIndices
        ..clear()
        ..addAll(cluster);
      _foundAlphaStartUs = _nowUs;
    });

    // 0.8s minimum hold — at the end, drain `_pendingPhaseAdvance` if set.
    _foundHoldTimer?.cancel();
    _foundHoldTimer = Timer(const Duration(milliseconds: 800), _onFoundHoldElapsed);
  }

  void _onFoundHoldElapsed() {
    if (!mounted) return;
    if (_pendingPhaseAdvance == PendantCeremonySignal.liveEntered) {
      // BLE moved past `connecting` while we were holding. Skip converge.
      _pendingPhaseAdvance = null;
      _enterGreeting();
    } else {
      _enterConverge();
    }
  }

  void _onLiveEntered() {
    // Buffer if a phase-hold timer is still running (it'll drain
    // `_pendingPhaseAdvance` on elapse). Otherwise advance immediately —
    // the prior bug (2026-05-05) was that `liveEntered` arriving AFTER
    // the converge timer had already fired would buffer indefinitely with
    // nothing to drain it, leaving the ceremony permanently stuck on the
    // "Setting up." beat even though BLE had reached `live`.
    switch (_phase) {
      case _CeremonyPhase.found:
        if (_foundHoldTimer?.isActive ?? false) {
          _pendingPhaseAdvance = PendantCeremonySignal.liveEntered;
        } else {
          _enterGreeting();
        }
        break;
      case _CeremonyPhase.converge:
        if (_convergeTimer?.isActive ?? false) {
          _pendingPhaseAdvance = PendantCeremonySignal.liveEntered;
        } else {
          _enterGreeting();
        }
        break;
      case _CeremonyPhase.drift:
        // Race: `pairingStarted` fired but `connectingEntered` hasn't yet
        // promoted us to `found`. Buffer — the next signal-driven phase
        // change will drain.
        _pendingPhaseAdvance = PendantCeremonySignal.liveEntered;
        break;
      case _CeremonyPhase.greeting:
        // Already there — no-op.
        break;
    }
  }

  void _enterConverge() {
    _refreshReducedMotion();
    _syncNowUs();
    setState(() {
      _phase = _CeremonyPhase.converge;
      _convergeStartUs = _nowUs;
    });
    final convergeDuration = _reducedMotion ? Duration.zero : const Duration(milliseconds: 800);
    _convergeTimer?.cancel();
    _convergeTimer = Timer(convergeDuration, () {
      if (!mounted) return;
      if (_pendingPhaseAdvance == PendantCeremonySignal.liveEntered) {
        _pendingPhaseAdvance = null;
        _enterGreeting();
      }
      // Otherwise: hold at "all converged" until liveEntered arrives.
    });
  }

  void _enterGreeting() {
    _refreshReducedMotion();
    _syncNowUs();
    setState(() {
      _phase = _CeremonyPhase.greeting;
      _greetingStartUs = _nowUs;
    });
    _greetingTimer?.cancel();
    _greetingTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      widget.onCeremonyComplete();
    });
  }

  void _enterFailed() {
    _refreshReducedMotion();
    _syncNowUs();
    setState(() {
      _failedStartUs = _nowUs;
    });
    _failedTimer?.cancel();
    _failedTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      widget.onCeremonyFailed();
    });
  }

  // ---------------------------------------------------------------------------
  // Per-frame integration
  // ---------------------------------------------------------------------------

  void _onTick() {
    if (!mounted) return;
    final now = _ticker.lastElapsedDuration ?? Duration.zero;
    final dtMicros = (now - _lastTick).inMicroseconds;
    _lastTick = now;
    final dt = dtMicros / 1e6;
    _nowUs = now.inMicroseconds;

    if (_phase == _CeremonyPhase.drift && !_reducedMotion) {
      for (final p in _particles) {
        p.tick(dt, _nowUs);
      }
    }
    // Other phases don't move particles per-tick — positions are sampled in
    // the painter from tween anchors. We still call setState so the painter
    // re-runs each frame.
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _refreshReducedMotion() {
    final mq = MediaQuery.maybeOf(context);
    _reducedMotion = mq?.disableAnimations ?? false;
  }

  /// Sync `_nowUs` from the ticker so phase-start anchors are recorded with
  /// the same time base the painter samples. Without this, a signal that
  /// arrives between ticks could anchor itself to a stale `_nowUs`.
  void _syncNowUs() {
    final elapsed = _ticker.lastElapsedDuration ?? Duration.zero;
    _nowUs = elapsed.inMicroseconds;
  }

  /// Pixel-space center of the confined area (which equals canvas center).
  Offset _confinedCenter() {
    return Offset(_canvasSize.width / 2, _canvasSize.height / 2);
  }

  /// The side length of the confined drift square.
  double _confinedSide() {
    return math.min(_canvasSize.width, _canvasSize.height) * 0.6;
  }

  /// Resolve a normalized (0..1) particle position to pixel-space inside the
  /// confined square (centered on canvas).
  Offset _resolvePixelPosition(Offset normalized) {
    final side = _confinedSide();
    final origin = Offset((_canvasSize.width - side) / 2, (_canvasSize.height - side) / 2);
    return origin + Offset(normalized.dx * side, normalized.dy * side);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    _refreshReducedMotion();
    return LayoutBuilder(
      builder: (context, constraints) {
        _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          fit: StackFit.expand,
          children: [
            // Particles (full-bleed CustomPainter).
            CustomPaint(
              painter: _ConstellationPainter(
                particles: _particles,
                phase: _phase,
                foundParticleIndices: _foundParticleIndices,
                canvasSize: _canvasSize,
                confinedSide: _confinedSide(),
                foundAlphaProgress: _progress01(_foundAlphaStartUs, const Duration(milliseconds: 200)),
                convergeProgress: _progress01(_convergeStartUs, const Duration(milliseconds: 800)),
                greetingProgress: _progress01(_greetingStartUs, const Duration(milliseconds: 1000)),
                failedProgress: _progress01(_failedStartUs, const Duration(milliseconds: 300)),
                reducedMotion: _reducedMotion,
                nowUs: _nowUs,
              ),
              size: Size.infinite,
            ),
            // Copy / overlay area. Two distinct positioning modes:
            //
            // 1. Failure overlay (failed phase + `widget.failureMessage`):
            //    centered in the lower half so the message + Try again +
            //    Back stack has breathing room. Particles drift at 30% alpha
            //    behind.
            // 2. Phase copy (drift / found / converge / greeting): anchored
            //    near the BOTTOM of the canvas in a small register so the
            //    constellation stays the protagonist (per 2026-05-05 dogfood:
            //    "we can place the search at the bottom with an small font
            //    size"). Drift phase gets the animated shimmer.
            if (_failedStartUs != null && widget.failureMessage != null && widget.onRetry != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                top: _canvasSize.height * 0.5,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
                    child: _buildCopyOrOverlay(),
                  ),
                ),
              )
            else
              Positioned(
                left: 0,
                right: 0,
                bottom: AppStyles.spacingXXL,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
                  child: _buildCopyOrOverlay(),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Returns 0..1 progress of an animation that started at [start] and runs
  /// for [duration]. Returns 0 if [start] is null. Returns 1 if elapsed
  /// exceeds [duration].
  double _progress01(int? startUs, Duration duration) {
    if (startUs == null) return 0;
    if (duration == Duration.zero) return 1;
    final elapsed = _nowUs - startUs;
    final ratio = elapsed / duration.inMicroseconds;
    if (ratio.isNaN || ratio < 0) return 0;
    if (ratio > 1) return 1;
    return ratio;
  }

  String _copyForPhase(_CeremonyPhase phase) {
    final c = widget.copy;
    switch (phase) {
      case _CeremonyPhase.drift:
        return c.searching;
      case _CeremonyPhase.found:
        return c.found;
      case _CeremonyPhase.converge:
        return c.settingUp;
      case _CeremonyPhase.greeting:
        return c.greeting;
    }
  }

  /// Renders the lower-third overlay area. Three modes:
  /// 1. Failure overlay (failed phase + `widget.failureMessage` set):
  ///    message text + "Try again" button stacked, particles drift behind.
  /// 2. Drift phase: phase copy with an animated horizontal shimmer.
  /// 3. Other phases: plain centered text with a 200ms cross-fade.
  Widget _buildCopyOrOverlay() {
    final isFailed = _failedStartUs != null;
    final hasFailureCopy = widget.failureMessage != null && widget.onRetry != null;

    if (isFailed && hasFailureCopy) {
      // Mode 1 — failure overlay inside the constellation. Two stacked
      // text-link buttons (NOT a filled dialog pill, per 2026-05-05 dogfood):
      // primary "Try again" in brand blue, secondary "Back" dimmer below.
      // Each button still meets the 44pt HIG touch target via
      // `minimumSize: Size.fromHeight(44)`.
      final retryLabel = widget.tryAgainLabel ?? 'Try again';
      final backLabel = widget.backLabel ?? 'Back';
      return Semantics(
        liveRegion: true,
        label: widget.failureMessage,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.failureMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w300,
                color: AppColors.textSecondary,
                letterSpacing: -0.1,
                height: 1.4,
              ),
            ),
            const SizedBox(height: AppStyles.spacingXL),
            Semantics(
              button: true,
              label: retryLabel,
              child: TextButton(
                onPressed: widget.onRetry,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.brandPrimary,
                  minimumSize: const Size.fromHeight(AppStyles.touchTargetMinimum),
                  padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
                ),
                child: Text(
                  retryLabel,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500, letterSpacing: -0.2),
                ),
              ),
            ),
            if (widget.onBack != null)
              Semantics(
                button: true,
                label: backLabel,
                child: TextButton(
                  onPressed: widget.onBack,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textTertiary,
                    minimumSize: const Size.fromHeight(AppStyles.touchTargetMinimum),
                    padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
                  ),
                  child: Text(
                    backLabel,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w400, letterSpacing: -0.1),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    // Modes 2 & 3 — phase copy. Shimmer only on drift phase.
    //
    // Type register: SMALL light weight + tertiary color so the copy reads
    // as a calm bottom-of-screen label (per 2026-05-05 dogfood: "we can
    // place the search at the bottom with an small font size"). The
    // constellation visual is the protagonist; the text just labels what's
    // happening, like Apple's "Searching for AirPods..." status copy.
    final text = _copyForPhase(_phase);
    final textWidget = Text(
      text,
      key: ValueKey<_CeremonyPhase>(_phase),
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: AppColors.textTertiary,
        letterSpacing: 0.1,
        height: 1.3,
      ),
    );

    final styled =
        (_phase == _CeremonyPhase.drift && !_reducedMotion)
            ? _ShimmerWrapper(nowUs: _nowUs, child: textWidget)
            : textWidget;

    return Semantics(
      liveRegion: true,
      label: text,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: styled,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shimmer wrapper for the "Searching." copy during the drift phase.
// ---------------------------------------------------------------------------

/// Animated horizontal-sweep shimmer over text. Drives the gradient stops
/// from the parent's `_nowUs` time so the shimmer is in lockstep with the
/// constellation ticker (no extra controller, no extra rebuild source).
class _ShimmerWrapper extends StatelessWidget {
  const _ShimmerWrapper({required this.child, required this.nowUs});

  final Widget child;
  final int nowUs;

  static const Duration _period = Duration(milliseconds: 1800);
  static const double _bandWidth = 0.35; // gradient bright-band half-width

  @override
  Widget build(BuildContext context) {
    final periodUs = _period.inMicroseconds;
    final t = ((nowUs % periodUs) / periodUs) * (1.0 + 2 * _bandWidth) - _bandWidth;

    return ShaderMask(
      shaderCallback: (rect) {
        return LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: const <Color>[
            Color(0xFF888888),
            AppColors.textPrimary,
            Color(0xFF888888),
          ],
          stops: <double>[
            (t - _bandWidth).clamp(0.0, 1.0),
            t.clamp(0.0, 1.0),
            (t + _bandWidth).clamp(0.0, 1.0),
          ],
        ).createShader(rect);
      },
      blendMode: BlendMode.srcIn,
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Particle model
// ---------------------------------------------------------------------------

class _Particle {
  _Particle({
    required this.rng,
    required this.position,
    required this.velocity,
    required this.baseRadius,
    required this.baseAlpha,
    required this.baseColor,
  }) : _targetVelocity = velocity,
       _directionLerpStartUs = 0,
       _lastDirectionRandomizeUs = 0;

  final math.Random rng;

  /// Normalized position in confined square (0..1 × 0..1). Constrained to
  /// the unit disk inscribed in this square (centered at (0.5, 0.5),
  /// radius 0.5) — see boundary check in [tick].
  Offset position;

  /// Velocity in confined-square-units per second. (Magnitude is in pt/s
  /// originally, but since the confined side is `min(w,h)*0.6`, we treat the
  /// magnitude here as pt/s and convert to confined-units in `tick`.)
  Offset velocity;

  /// New velocity we're lerping toward. Re-randomized every 1.5s with an
  /// 800ms `Curves.linear` lerp.
  Offset _targetVelocity;
  int _directionLerpStartUs;
  int _lastDirectionRandomizeUs;

  final double baseRadius;
  final double baseAlpha;

  /// Per-particle color picked once at init from `_kParticleColors`. Drives
  /// the Apple-Watch-nebula star-variety look; particles otherwise share
  /// only their alpha and radius variation.
  final Color baseColor;

  void tick(double dt, int nowUs) {
    // Re-randomize direction every 1.5s.
    if (nowUs - _lastDirectionRandomizeUs >= const Duration(milliseconds: 1500).inMicroseconds) {
      final speed = velocity.distance.clamp(8.0, 18.0);
      final angle = rng.nextDouble() * 2 * math.pi;
      _targetVelocity = Offset(math.cos(angle) * speed, math.sin(angle) * speed);
      _directionLerpStartUs = nowUs;
      _lastDirectionRandomizeUs = nowUs;
    }

    // Lerp velocity toward target over 800ms.
    final lerpElapsed = (nowUs - _directionLerpStartUs) / 1e6;
    const lerpDuration = 0.8;
    if (lerpElapsed < lerpDuration) {
      final t = lerpElapsed / lerpDuration;
      velocity = Offset.lerp(velocity, _targetVelocity, t * dt / lerpDuration) ?? velocity;
    } else {
      velocity = _targetVelocity;
    }

    // Integrate position. Velocity is pt/s; the confined square side in
    // pixels is dynamic. To keep `position` normalized, we scale by an
    // assumed confined-unit-equivalent: 1 confined unit ≈ confinedSide px.
    // For determinism we treat each unit-of-velocity as 1pt and divide by a
    // canonical confined size of 200pt (typical iPhone visible area for the
    // confined square at min(w,h)*0.6). This gives smooth drift across all
    // device sizes; exactness isn't load-bearing for the visual.
    const canonicalConfinedSide = 200.0;
    var nx = position.dx + velocity.dx * dt / canonicalConfinedSide;
    var ny = position.dy + velocity.dy * dt / canonicalConfinedSide;

    // Reflect off the unit-disk boundary (centered at (0.5, 0.5), r=0.5).
    final dx = nx - 0.5;
    final dy = ny - 0.5;
    final distSq = dx * dx + dy * dy;
    const radiusSq = 0.25; // 0.5²
    if (distSq > radiusSq) {
      final dist = math.sqrt(distSq);
      // Outward unit normal at the contact point.
      final nrx = dx / dist;
      final nry = dy / dist;
      // Push back to the disk edge.
      nx = 0.5 + nrx * 0.5;
      ny = 0.5 + nry * 0.5;
      // Reflect velocity along the radial normal: v' = v - 2(v·n)n.
      final dot = velocity.dx * nrx + velocity.dy * nry;
      velocity = Offset(velocity.dx - 2 * dot * nrx, velocity.dy - 2 * dot * nry);
      final tdot = _targetVelocity.dx * nrx + _targetVelocity.dy * nry;
      _targetVelocity = Offset(_targetVelocity.dx - 2 * tdot * nrx, _targetVelocity.dy - 2 * tdot * nry);
    }

    position = Offset(nx, ny);
  }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

class _ConstellationPainter extends CustomPainter {
  _ConstellationPainter({
    required this.particles,
    required this.phase,
    required this.foundParticleIndices,
    required this.canvasSize,
    required this.confinedSide,
    required this.foundAlphaProgress,
    required this.convergeProgress,
    required this.greetingProgress,
    required this.failedProgress,
    required this.reducedMotion,
    required this.nowUs,
  });

  final List<_Particle> particles;
  final _CeremonyPhase phase;
  final Set<int> foundParticleIndices;
  final Size canvasSize;
  final double confinedSide;
  final double foundAlphaProgress;
  final double convergeProgress;
  final double greetingProgress;
  final double failedProgress;
  final bool reducedMotion;
  /// Wall-time-ish microseconds (ticker-elapsed). Used by the converge-end
  /// "waiting orb" pulse so it breathes independently of phase progress
  /// (which is monotonic 0→1, can't oscillate on its own).
  final int nowUs;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final origin = Offset((size.width - confinedSide) / 2, (size.height - confinedSide) / 2);

    Offset toPixels(Offset normalized) {
      return origin + Offset(normalized.dx * confinedSide, normalized.dy * confinedSide);
    }

    // Failure fade affects everything. Dims to 30% (not 0%) so the particles
    // stay visible as ambient backdrop while the failure overlay (message +
    // Try again button) renders inside the constellation widget. Per dogfood
    // 2026-05-05: "the try agains should be the same screen / part of the
    // costellation" — the constellation no longer disappears on failure.
    final failedAlphaMul = 1.0 - failedProgress * 0.7;

    // Greeting fades the particle group out over the first 200ms and the
    // orb in over the same window; orb scale tween runs over 1.0s (skipped
    // under reduced motion).
    final greetingFadeOutMul = phase == _CeremonyPhase.greeting ? (1.0 - (greetingProgress * 5).clamp(0.0, 1.0)) : 1.0;

    // Draw particles.
    for (var i = 0; i < particles.length; i++) {
      final p = particles[i];
      final basePixel = toPixels(p.position);

      Offset pos = basePixel;
      if (phase == _CeremonyPhase.converge) {
        // Stagger: delay = i * (80ms / particleCount).
        final staggerMs = i * (80.0 / particles.length);
        const totalMs = 800.0;
        final localT = ((convergeProgress * totalMs - staggerMs) / (totalMs - staggerMs)).clamp(0.0, 1.0);
        final eased = Curves.easeInQuart.transform(localT);
        pos = Offset.lerp(basePixel, center, eased) ?? basePixel;
      } else if (phase == _CeremonyPhase.greeting) {
        // After converge we're at center already; greeting just fades.
        pos = center;
      }

      final isInFoundCluster = foundParticleIndices.contains(i);

      // Alpha computation.
      double alpha = p.baseAlpha;
      if (phase == _CeremonyPhase.found) {
        if (isInFoundCluster) {
          alpha = p.baseAlpha + (1.0 - p.baseAlpha) * foundAlphaProgress;
        }
      } else if (phase == _CeremonyPhase.converge) {
        alpha = p.baseAlpha + (1.0 - p.baseAlpha) * convergeProgress;
      } else if (phase == _CeremonyPhase.greeting) {
        alpha = 1.0;
      }
      alpha *= greetingFadeOutMul;
      alpha *= failedAlphaMul;
      alpha = alpha.clamp(0.0, 1.0);

      if (alpha <= 0) continue;

      // Brightened-cluster radius bump (Found + Converge): grows during Found
      // alongside the alpha tween, holds at full bump through Converge.
      double radius = p.baseRadius;
      if (isInFoundCluster) {
        if (phase == _CeremonyPhase.found) {
          radius = p.baseRadius * (1.0 + (_kFoundRadiusMultiplier - 1.0) * foundAlphaProgress);
        } else if (phase == _CeremonyPhase.converge) {
          radius = p.baseRadius * _kFoundRadiusMultiplier;
        }
      }

      final paint = Paint()..color = p.baseColor.withValues(alpha: alpha);
      canvas.drawCircle(pos, radius, paint);
    }

    // Converge-end "waiting orb" — fades in over the last 25% of the
    // converge tween and pulses at ~10 BPM (6s period) while we hold at
    // converged-state waiting for `liveEntered`. Without this, all 5000
    // particles stack at the canvas center but their max radius (3.5pt)
    // makes the visible cluster only ~7pt wide — too small to read as
    // "I'm working on it." (Per 2026-05-05 dogfood.)
    if (phase == _CeremonyPhase.converge && convergeProgress > 0.75 && failedAlphaMul > 0) {
      final fadeIn = ((convergeProgress - 0.75) / 0.25).clamp(0.0, 1.0);
      double scale = 1.0;
      double pulseAlphaMul = 1.0;
      if (!reducedMotion) {
        // 6s breathing period. sin range -1..1 → 0..1.
        final phase = (nowUs % 6000000) / 6000000.0;
        final s = math.sin(phase * 2 * math.pi);
        scale = 1.0 + 0.06 * s; // 0.94 ↔ 1.06
        pulseAlphaMul = 0.85 + 0.15 * (s * 0.5 + 0.5); // 0.85..1.0
      }
      final waitOrbAlpha = 0.7 * fadeIn * pulseAlphaMul * failedAlphaMul;
      final waitOrbPaint = Paint()..color = AppColors.brandPrimary.withValues(alpha: waitOrbAlpha);
      canvas.drawCircle(center, 32 * scale, waitOrbPaint);
    }

    // Greeting orb (fades in as particles fade out).
    if (phase == _CeremonyPhase.greeting && failedAlphaMul > 0) {
      final orbAlphaIn = (greetingProgress * 5).clamp(0.0, 1.0); // 200ms fade in
      final orbAlpha = 0.85 * orbAlphaIn * failedAlphaMul;
      double scale = 1.0;
      if (!reducedMotion) {
        // Scale 1.0 → 1.08 → 1.0 once over 1.0s, easeInOutSine.
        final t = greetingProgress.clamp(0.0, 1.0);
        // A symmetric sine bump: 4 * t * (1 - t) peaks at 1.0 when t = 0.5.
        final eased = Curves.easeInOutSine.transform(4 * t * (1 - t));
        scale = 1.0 + 0.08 * eased;
      }
      final orbPaint = Paint()..color = AppColors.brandPrimary.withValues(alpha: orbAlpha);
      canvas.drawCircle(center, 40 * scale, orbPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ConstellationPainter oldDelegate) => true;
}
