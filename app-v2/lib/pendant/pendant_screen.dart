import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:provider/provider.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/pendant/pendant_constellation.dart';
import 'package:nooto_v2/pendant/pendant_orb.dart';
import 'package:nooto_v2/pendant/pendant_unpaired_surface_card.dart';
import 'package:nooto_v2/providers/auth_provider.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/providers/pendant_stt_provider.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Internal layout selector for [PendantScreen].
///
/// Per the design doc — `matheusoliviera-main-design-pendant-magic-moment-`
/// `20260504-124235.md` (see "File plan" → `pendant_screen.dart` rewrite
/// section) — the screen has three exhaustive layout modes:
///
/// - [_LayoutMode.takeover] — full-bleed [PendantConstellation] ceremony,
///   no AppBar. Driven by `_ceremonyArmed && (pairing | connecting | live)`.
/// - [_LayoutMode.settledPaired] — Scaffold + AppBar, ambient [PendantOrb]
///   above the device-info card. State-coded orb intensity.
/// - [_LayoutMode.settledUnpaired] — Scaffold + AppBar, single
///   [PendantUnpairedSurfaceCard]. Used for unpaired, permission-denied,
///   incompatible, and ceremony-failure variants.
enum _LayoutMode { takeover, settledPaired, settledUnpaired }

/// Distinct ceremony failure kinds. Used to remember which AI-voiced error
/// surface to render after the ceremony exits to settledUnpaired (per DR-2).
enum _CeremonyFailureKind { timeout, bleError, incompatible, bluetoothOff }

/// Dedicated full-screen pendant connection UI.
///
/// Reachable from the kebab menu (Lane E v0). Coexists with the chat-step
/// turn, status pill, connect-pendant voice card, and pairing sheet from
/// earlier lanes — none of them is removed.
///
/// ## Constellation signal flow
///
/// ```
///   PendantProvider.info  ──►  PendantScreen (this)
///         (BLE state)              │
///                                  │ detects transitions, emits signals
///                                  ▼
///                    StreamController<PendantCeremonySignal>
///                                  │
///                                  ▼
///                          PendantConstellation
/// ```
///
/// Each layout-flip is a function of `(PendantInfo.state, _ceremonyArmed)`.
/// The arm flag is set by tapping the Pair CTA and cleared on (a) successful
/// settled-paired transition, (b) ceremony failure, (c) any settledUnpaired
/// flip (per CQ-2 uniform arm-clearing rule), or (d) screen unmount.
class PendantScreen extends StatefulWidget {
  const PendantScreen({super.key, this.openAppSettings});

  /// Test seam — production callers omit and we use the platform helper.
  final Future<bool> Function()? openAppSettings;

  /// Convenience constructor for callers in the kebab menu and elsewhere.
  static Route<void> route() => MaterialPageRoute(builder: (_) => const PendantScreen());

  @override
  State<PendantScreen> createState() => _PendantScreenState();
}

class _PendantScreenState extends State<PendantScreen> {
  /// Set on Pair CTA tap; cleared on ceremony complete/fail and on any
  /// transition into [_LayoutMode.settledUnpaired] (CQ-2).
  bool _ceremonyArmed = false;

  /// True after the constellation reaches its 300ms failure-fade state and
  /// before the user taps Try Again or pops the screen. Keeps the takeover
  /// layout active so the constellation widget stays mounted at 30% alpha
  /// behind the failure overlay (per dogfood 2026-05-05: "the try agains
  /// should be the same screen / part of the costellation"). Without this,
  /// the screen would flip to the settled-unpaired surface card and unmount
  /// the constellation.
  bool _failureOverlayActive = false;

  /// Last [PendantState] we observed via the [PendantProvider]. Used to
  /// detect transitions and emit ceremony signals.
  PendantState? _lastObservedState;

  /// Remembered failure kind so the screen can render the right AI-voiced
  /// error surface card after the ceremony exits to settledUnpaired.
  _CeremonyFailureKind? _lastFailureKind;

  /// Broadcast stream of signals consumed by [PendantConstellation].
  final StreamController<PendantCeremonySignal> _signalsController =
      StreamController<PendantCeremonySignal>.broadcast();

  PendantProvider? _provider;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.read<PendantProvider>();
    if (!identical(next, _provider)) {
      _provider?.removeListener(_onProviderChanged);
      _provider = next;
      _provider!.addListener(_onProviderChanged);
      // Seed the last-observed state so the next change is treated as a
      // transition, not a first frame.
      _lastObservedState = _provider!.info.state;
    }
  }

  @override
  void dispose() {
    _provider?.removeListener(_onProviderChanged);
    _signalsController.close();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Provider listener — reacts to BLE state transitions OUTSIDE of build.
  // ---------------------------------------------------------------------------

  void _onProviderChanged() {
    if (!mounted) return;
    final info = _provider!.info;
    final prev = _lastObservedState;
    final next = info.state;
    _lastObservedState = next;

    if (prev == next) return;

    // Emit ceremony signals when armed.
    if (_ceremonyArmed) {
      // pairing → connecting → found
      if (prev == PendantState.pairing && next == PendantState.connecting) {
        _signalsController.add(PendantCeremonySignal.connectingEntered);
      }
      // connecting → live → greeting
      if (prev == PendantState.connecting && next == PendantState.live) {
        _signalsController.add(PendantCeremonySignal.liveEntered);
      }
      // pairing → unpaired (timeout / cancellation / Bluetooth off).
      // OmiPendant.startPair sets `wasLastPairAttemptBluetoothOff = true`
      // when iOS reports `CBManagerStateUnknown` / `CBManagerStatePoweredOff`
      // during scan — distinct surface card with "Bluetooth's off" copy
      // instead of the generic "couldn't find a pendant" timeout copy.
      if (prev == PendantState.pairing && next == PendantState.unpaired) {
        _lastFailureKind = _provider!.wasLastPairAttemptBluetoothOff
            ? _CeremonyFailureKind.bluetoothOff
            : _CeremonyFailureKind.timeout;
        _signalsController.add(PendantCeremonySignal.failed);
        _failureOverlayActive = true;
      }
      // connecting → unpaired (BLE error mid-connect)
      if (prev == PendantState.connecting && next == PendantState.unpaired) {
        _lastFailureKind = _CeremonyFailureKind.bleError;
        _signalsController.add(PendantCeremonySignal.failed);
        _failureOverlayActive = true;
      }
      // {pairing|connecting} → incompatible (mid-ceremony incompatible flip)
      if ((prev == PendantState.pairing || prev == PendantState.connecting) && next == PendantState.incompatible) {
        _lastFailureKind = _CeremonyFailureKind.incompatible;
        _signalsController.add(PendantCeremonySignal.failed);
        _failureOverlayActive = true;
      }
      // connecting → reconnecting (BLE handshake failed during initial pair —
      // OmiPendant catch block routes through `_onTransportDisconnect`, which
      // sets `reconnecting` even on the first failure). Treat as ceremony BLE
      // error so the user sees a clear failure card instead of a flickering
      // orb on a settledPaired layout that doesn't make sense for a pair
      // attempt that never completed.
      if (prev == PendantState.connecting && next == PendantState.reconnecting) {
        _lastFailureKind = _CeremonyFailureKind.bleError;
        _signalsController.add(PendantCeremonySignal.failed);
        _failureOverlayActive = true;
      }
    }

    // CQ-2 uniform arm-clearing: any settledUnpaired transition clears the
    // arm flag. The constellation widget owns its own teardown via the
    // `failed` signal we emit above; here we only ensure layout correctness
    // for the next build.
    final layout = _selectLayoutFor(info);
    if (layout == _LayoutMode.settledUnpaired && _ceremonyArmed) {
      // Defensive — covers any settledUnpaired entry path we didn't model
      // explicitly above (e.g. permissionDenied during ceremony).
      _ceremonyArmed = false;
    }

    // Trigger a rebuild — Provider's notifyListeners has already invoked us,
    // but we have screen-local state (_ceremonyArmed, _lastFailureKind) that
    // may have changed and needs to render.
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Layout selection
  // ---------------------------------------------------------------------------

  _LayoutMode _selectLayoutFor(PendantInfo info) {
    // Failure overlay keeps the takeover layout active across the
    // settled-unpaired BLE state so the constellation widget stays mounted
    // and renders the in-canvas Try Again UI. Cleared on retry tap, screen
    // dismiss, or successful re-pair.
    if (_failureOverlayActive) return _LayoutMode.takeover;
    switch (info.state) {
      case PendantState.unpaired:
      case PendantState.permissionDenied:
      case PendantState.incompatible:
        return _LayoutMode.settledUnpaired;
      case PendantState.pairing:
        return _ceremonyArmed ? _LayoutMode.takeover : _LayoutMode.settledUnpaired;
      case PendantState.connecting:
        // Armed: takeover (first-pair). Not armed: settledPaired with
        // flickering orb (offline → reconnect path).
        return _ceremonyArmed ? _LayoutMode.takeover : _LayoutMode.settledPaired;
      case PendantState.live:
        // Armed: takeover (greeting beat). Not armed: settledPaired.
        return _ceremonyArmed ? _LayoutMode.takeover : _LayoutMode.settledPaired;
      case PendantState.reconnecting:
      case PendantState.offline:
      case PendantState.interrupted:
        return _LayoutMode.settledPaired;
    }
  }

  // ---------------------------------------------------------------------------
  // Pair / Try Again CTA
  // ---------------------------------------------------------------------------

  void _onPairTap() {
    setState(() {
      _ceremonyArmed = true;
      _lastFailureKind = null;
      _failureOverlayActive = false;
    });
    // Constellation listens for `pairingStarted` to enter the drift phase.
    _signalsController.add(PendantCeremonySignal.pairingStarted);
    context.read<PendantProvider>().startPair();
  }

  void _onCeremonyComplete() {
    if (!mounted) return;
    setState(() {
      _ceremonyArmed = false;
      _lastFailureKind = null;
      _failureOverlayActive = false;
    });
  }

  /// Called by the constellation widget 300ms after the `failed` signal
  /// (once particles have dimmed to 30% alpha). The constellation stays
  /// mounted; we just flip into failure-overlay mode so the screen's
  /// `_buildTakeover` re-renders with `failureMessage` + `onRetry` props,
  /// and the constellation's own copy area shows the message + Try Again
  /// button.
  void _onCeremonyFailed() {
    if (!mounted) return;
    setState(() {
      _ceremonyArmed = false;
      _failureOverlayActive = true;
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final info = context.watch<PendantProvider>().info;
    final layout = _selectLayoutFor(info);

    final Widget body;
    switch (layout) {
      case _LayoutMode.takeover:
        body = _buildTakeover(l);
        break;
      case _LayoutMode.settledPaired:
        body = _buildSettledPaired(info, l);
        break;
      case _LayoutMode.settledUnpaired:
        body = _buildSettledUnpaired(info, l);
        break;
    }

    // Cross-fade between layout modes so the unpaired-CTA → ceremony, the
    // ceremony → settled-connected, and settled → re-pair transitions feel
    // continuous instead of swapping abruptly. 320ms ease-out is comfortably
    // perceptible without dragging. Same dark scaffold color across all
    // layouts means the chrome (AppBar, surface card) just fades in/out
    // over a stable backdrop. (2026-05-05 dogfood: "smooth the transition
    // or add transitions between screens.")
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: KeyedSubtree(key: ValueKey<_LayoutMode>(layout), child: body),
    );
  }

  Widget _buildTakeover(AppLocalizations l) {
    // Build localized ceremony copy here so the constellation widget stays
    // l10n-agnostic. Display name doesn't change mid-pairing in practice, so
    // `context.read` is sufficient — the screen rebuilds on PendantProvider
    // changes anyway, which is enough churn to pick up any name change.
    final displayName = context.read<AuthChangeProvider>().displayName;
    final greeting = (displayName != null && displayName.isNotEmpty)
        ? l.pendantCeremonyGreetingNamed(displayName)
        : l.pendantCeremonyGreetingFallback;
    final copy = PendantCeremonyCopy(
      searching: l.pendantCeremonySearching,
      found: l.pendantCeremonyFound,
      settingUp: l.pendantCeremonySettingUp,
      greeting: greeting,
    );

    // Compute failure overlay copy if we're in failure-overlay mode.
    String? failureMessage;
    if (_failureOverlayActive && _lastFailureKind != null) {
      switch (_lastFailureKind!) {
        case _CeremonyFailureKind.timeout:
          failureMessage = l.pendantCeremonyTimeout;
          break;
        case _CeremonyFailureKind.bleError:
          failureMessage = l.pendantCeremonyBleError;
          break;
        case _CeremonyFailureKind.incompatible:
          failureMessage = l.pendantCeremonyIncompatible;
          break;
        case _CeremonyFailureKind.bluetoothOff:
          failureMessage = l.pendantCeremonyBluetoothOff;
          break;
      }
    }

    // No AppBar — full-bleed ceremony. Constellation uses the entire screen.
    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      body: SafeArea(
        child: PendantConstellation(
          signals: _signalsController.stream,
          copy: copy,
          onCeremonyComplete: _onCeremonyComplete,
          onCeremonyFailed: _onCeremonyFailed,
          failureMessage: failureMessage,
          tryAgainLabel: failureMessage != null ? l.pendantPairTryAgain : null,
          onRetry: failureMessage != null ? _onPairTap : null,
          // Back link only shows in failure-overlay mode. Pops the route so
          // the user can leave Pendant without retrying. Uses the existing
          // `pendantScreenBackLabel` if l10n has it, otherwise null label
          // (the constellation widget falls back to "Back").
          onBack: failureMessage != null ? () => Navigator.of(context).maybePop() : null,
        ),
      ),
    );
  }

  Widget _buildSettledPaired(PendantInfo info, AppLocalizations l) {
    final intensity = _orbIntensityFor(info.state);
    final provider = context.read<PendantProvider>();
    // Audio reactivity is meaningful only when the pendant is actively
    // streaming (`live`). On other paired states the orb's intensity recipe
    // (flickering / dim) carries the meaning instead.
    final audioLevel = info.state == PendantState.live ? provider.audioActivity : null;

    // No AppBar — full-bleed dark scaffold matching the takeover layout.
    // Stack with three positioned children:
    //   1. Floating back text-link top-left.
    //   2. Orb + device-info group centered vertically + horizontally on
    //      the screen (per 2026-05-05 dogfood: "centralize the information
    //      into the screen except the disconnect").
    //   3. Disconnect / Reconnect action anchored at the bottom.
    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: AppStyles.spacingS,
              left: AppStyles.spacingS,
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.chevron_left, size: 22, color: AppColors.textSecondary),
                label: Text(
                  l.pendantScreenBackLabel,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                    color: AppColors.textSecondary,
                    letterSpacing: -0.1,
                  ),
                ),
                style: TextButton.styleFrom(
                  minimumSize: const Size(AppStyles.touchTargetMinimum, AppStyles.touchTargetMinimum),
                  padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingS),
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    PendantOrb(intensity: intensity, audioLevel: audioLevel),
                    // Live transcription replaces the abstract audio
                    // waveform — concrete words are a more legible
                    // "audio-is-flowing" signal than dancing bars
                    // (per 2026-05-05 dogfood). Sized to match the
                    // waveform's prior vertical footprint so the layout
                    // stays stable when the transcript is empty.
                    if (info.state == PendantState.live) ...[
                      const SizedBox(height: AppStyles.spacingL),
                      const _LiveTranscriptionPreview(),
                    ],
                    const SizedBox(height: AppStyles.spacingXL),
                    _PairedDeviceInfo(info: info, l: l),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: AppStyles.spacingXL,
              child: Center(child: _PairedActions(info: info, l: l)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettledUnpaired(PendantInfo info, AppLocalizations l) {
    final card = _surfaceCardFor(info, l);
    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: _appBar(l),
      // Center the card vertically in the body so the failure / unpaired
      // surface doesn't cling to the top with a vast empty void below
      // (2026-05-05 dogfood: "the main issue here is the UX of the try
      // again... so ugly"). Card hugs its content height via
      // `MainAxisSize.min` inside [PendantUnpairedSurfaceCard].
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
          child: Center(child: card),
        ),
      ),
    );
  }

  AppBar _appBar(AppLocalizations l) {
    return AppBar(
      backgroundColor: AppColors.backgroundPrimary,
      elevation: 0,
      title: Text(
        l.pendantScreenTitle,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
      ),
      leading: const BackButton(color: AppColors.textPrimary),
    );
  }

  PendantOrbIntensity _orbIntensityFor(PendantState state) {
    switch (state) {
      case PendantState.live:
        return PendantOrbIntensity.breathing;
      case PendantState.connecting:
      case PendantState.reconnecting:
        return PendantOrbIntensity.flickering;
      case PendantState.offline:
      case PendantState.interrupted:
        return PendantOrbIntensity.dim;
      // Defensive — settledPaired layout shouldn't fire for these, but
      // give a safe fallback.
      case PendantState.unpaired:
      case PendantState.permissionDenied:
      case PendantState.incompatible:
      case PendantState.pairing:
        return PendantOrbIntensity.dim;
    }
  }

  PendantUnpairedSurfaceCard _surfaceCardFor(PendantInfo info, AppLocalizations l) {
    // Ceremony-failure entries take priority over the raw state — the user
    // came from a ceremony so they should see the AI-voiced failure copy.
    if (_lastFailureKind != null) {
      switch (_lastFailureKind!) {
        case _CeremonyFailureKind.timeout:
          return PendantUnpairedSurfaceCard(
            message: l.pendantCeremonyTimeout,
            primaryCtaLabel: l.pendantPairTryAgain,
            onPrimaryTap: _onPairTap,
          );
        case _CeremonyFailureKind.bleError:
          return PendantUnpairedSurfaceCard(
            message: l.pendantCeremonyBleError,
            primaryCtaLabel: l.pendantPairTryAgain,
            onPrimaryTap: _onPairTap,
          );
        case _CeremonyFailureKind.incompatible:
          return PendantUnpairedSurfaceCard(
            message: l.pendantCeremonyIncompatible,
            primaryCtaLabel: l.pendantPairTryAgain,
            onPrimaryTap: _onPairTap,
          );
        case _CeremonyFailureKind.bluetoothOff:
          return PendantUnpairedSurfaceCard(
            message: l.pendantCeremonyBluetoothOff,
            primaryCtaLabel: l.pendantPairTryAgain,
            onPrimaryTap: _onPairTap,
          );
      }
    }

    switch (info.state) {
      case PendantState.permissionDenied:
        final opener = widget.openAppSettings ?? _openAppSettingsDefault;
        return PendantUnpairedSurfaceCard(
          message: l.pendantPairPermissionDenied,
          primaryCtaLabel: l.pendantPairOpenSettings,
          onPrimaryTap: () => opener(),
        );
      case PendantState.incompatible:
        // Pre-pair incompatible (no ceremony lead-in) keeps the existing
        // functional copy per design doc DR-2.
        return PendantUnpairedSurfaceCard(
          message: l.pendantPairIncompatible,
          primaryCtaLabel: l.pendantPairTryAgain,
          onPrimaryTap: _onPairTap,
        );
      case PendantState.pairing:
        // Defensive — `pairing` without arm shouldn't normally fire, but if
        // it does, render the same hint card the user would see if they
        // hadn't tapped yet.
        return PendantUnpairedSurfaceCard(
          message: l.pendantScreenPairHint,
          primaryCtaLabel: l.pendantScreenPairCta,
          onPrimaryTap: _onPairTap,
        );
      case PendantState.unpaired:
      default:
        return PendantUnpairedSurfaceCard(
          message: l.pendantScreenPairHint,
          primaryCtaLabel: l.pendantScreenPairCta,
          onPrimaryTap: _onPairTap,
        );
    }
  }
}

Future<bool> _openAppSettingsDefault() => ph.openAppSettings();

// ---------------------------------------------------------------------------
// Settled-paired sub-widgets
// ---------------------------------------------------------------------------

/// Device info card under the orb — name, codec badge, battery row.
///
/// Per design doc DR-1, the device name is a SUPPORTING LABEL (16pt weight
/// 400, textSecondary), NOT a primary heading. The orb above wins focus.
class _PairedDeviceInfo extends StatelessWidget {
  const _PairedDeviceInfo({required this.info, required this.l});

  final PendantInfo info;
  final AppLocalizations l;

  @override
  Widget build(BuildContext context) {
    final deviceName = info.deviceName ?? l.pendantScreenDefaultDeviceName;
    final battery = info.batteryPercent;
    final codec = info.codec;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Supporting label — weight 400, NOT a heading (DR-1).
        Text(
          deviceName,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w400, color: AppColors.textSecondary),
        ),
        if (codec != null) ...[
          const SizedBox(height: AppStyles.spacingS),
          _CodecBadge(label: l.pendantScreenCodecLabel(codec.name)),
        ],
        if (battery != null) ...[
          const SizedBox(height: AppStyles.spacingS),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.battery_full, size: 16, color: AppColors.textTertiary),
              const SizedBox(width: AppStyles.spacingS),
              Text(
                l.pendantScreenBatteryLabel(battery),
                style: const TextStyle(fontSize: 14, color: AppColors.textTertiary),
              ),
            ],
          ),
        ],
        // Secondary status copy under the orb for non-live states.
        if (info.state == PendantState.reconnecting) ...[
          const SizedBox(height: AppStyles.spacingS),
          Text(l.pendantPillReconnecting, style: const TextStyle(fontSize: 14, color: AppColors.textTertiary)),
        ] else if (info.state == PendantState.connecting) ...[
          const SizedBox(height: AppStyles.spacingS),
          Text(l.pendantPillConnecting, style: const TextStyle(fontSize: 14, color: AppColors.textTertiary)),
        ] else if (info.state == PendantState.offline) ...[
          const SizedBox(height: AppStyles.spacingS),
          Text(
            l.pendantPillOfflineSince(_formatTime(info.offlineSince)),
            style: const TextStyle(fontSize: 14, color: AppColors.textTertiary),
          ),
        ] else if (info.state == PendantState.interrupted) ...[
          const SizedBox(height: AppStyles.spacingS),
          Text(
            l.pendantScreenInterruptedExplain,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: AppColors.textTertiary, height: 1.4),
          ),
        ],
      ],
    );
  }

  String _formatTime(DateTime? when) {
    if (when == null) return '';
    final h = when.hour.toString().padLeft(2, '0');
    final m = when.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class _PairedActions extends StatelessWidget {
  const _PairedActions({required this.info, required this.l});

  final PendantInfo info;
  final AppLocalizations l;

  @override
  Widget build(BuildContext context) {
    // Text-link buttons matching the in-constellation Try Again / Back
    // and the unpaired Pair Pendant grammar (per 2026-05-05 dogfood:
    // "match the layout"). Brand-blue text-link for primary, no chrome.
    switch (info.state) {
      case PendantState.live:
        return TextButton(
          onPressed: () => context.read<PendantProvider>().disconnect(),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.textTertiary,
            minimumSize: const Size.fromHeight(AppStyles.touchTargetMinimum),
            padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
          ),
          child: Text(
            l.pendantScreenDisconnectCta,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w400, letterSpacing: -0.1),
          ),
        );
      case PendantState.offline:
        return TextButton(
          onPressed: () => context.read<PendantProvider>().reconnect(),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.brandPrimary,
            minimumSize: const Size.fromHeight(AppStyles.touchTargetMinimum),
            padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
          ),
          child: Text(
            l.pendantScreenReconnectCta,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500, letterSpacing: -0.2),
          ),
        );
      case PendantState.reconnecting:
      case PendantState.interrupted:
      case PendantState.connecting:
        // Paused / actively-recovering states — no action button. The orb's
        // intensity carries the activity signal.
        return const SizedBox.shrink();
      // Defensive — settledPaired layout shouldn't fire for these.
      case PendantState.unpaired:
      case PendantState.permissionDenied:
      case PendantState.incompatible:
      case PendantState.pairing:
        return const SizedBox.shrink();
    }
  }
}

class _CodecBadge extends StatelessWidget {
  const _CodecBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingM, vertical: AppStyles.spacingXS),
      decoration: BoxDecoration(
        color: AppColors.backgroundTertiary,
        borderRadius: BorderRadius.circular(AppStyles.radiusPill),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.textSecondary),
      ),
    );
  }
}

/// Live transcription preview on the connected pendant screen.
///
/// Reads from `PendantProvider.liveTranscript` — the rolling buffer of
/// transcript segments pushed back by backend Deepgram over the same
/// `v4/listen` WebSocket the pendant audio streams out on. Per 2026-05-05
/// dogfood: this reflects what the PENDANT actually heard, not the phone
/// mic. No on-device STT, no Opus decode — the backend already does the
/// work and pushes results back over the existing socket.
class _LiveTranscriptionPreview extends StatelessWidget {
  const _LiveTranscriptionPreview();

  @override
  Widget build(BuildContext context) {
    final stt = context.watch<PendantSttProvider>();
    return ValueListenableBuilder<String>(
      valueListenable: stt.liveTranscript,
      builder: (context, transcript, _) {
        final hasText = transcript.isNotEmpty;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              hasText ? transcript : '',
              key: ValueKey<String>(transcript),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w300,
                color: AppColors.textSecondary,
                letterSpacing: -0.1,
                height: 1.4,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Siri-style audio waveform — 7 vertical bars whose heights ripple per
/// bar with a phase offset, scaled by the live audio activity level.
///
/// Per 2026-05-05 dogfood: "I can see it connected but I have no way to
/// make sure we are receiving audio." The orb's audio reactivity (subtle
/// scale + alpha bump) wasn't legible enough; this waveform makes audio
/// flow visually unambiguous. Bars sit at a faint baseline pulse during
/// silence (~0.15 of full range) so the user can also see "I'm alive,
/// just nothing to hear" rather than misreading silence as "broken."
///
/// Drives off the same `audioActivity` ValueListenable as the orb.
class _AudioWaveform extends StatefulWidget {
  const _AudioWaveform({required this.audioLevel});

  final ValueListenable<double> audioLevel;

  @override
  State<_AudioWaveform> createState() => _AudioWaveformState();
}

class _AudioWaveformState extends State<_AudioWaveform> with SingleTickerProviderStateMixin {
  static const int _barCount = 7;
  static const double _barWidth = 4;
  static const double _barSpacing = 4;
  static const double _minHeight = 6;
  static const double _maxHeight = 36;

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        height: _maxHeight,
        child: AnimatedBuilder(
          animation: Listenable.merge([_controller, widget.audioLevel]),
          builder: (context, _) {
            final level = widget.audioLevel.value.clamp(0.0, 1.0);
            // Mix in a gentle 0.15 baseline so silence still has subtle
            // motion (signals "alive, listening, just quiet").
            final amplitude = 0.15 + level * 0.85;
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: List<Widget>.generate(_barCount, (i) {
                // Phase per bar — distributes the wave so bars don't
                // bounce in unison. Symmetric around the center bar.
                final phase = ((i - _barCount / 2) / _barCount) + _controller.value;
                final wavePos = (1.0 + math.sin(phase * 2 * math.pi)) / 2; // 0..1
                final h = _minHeight + (_maxHeight - _minHeight) * amplitude * wavePos;
                final alpha = (0.4 + 0.6 * level).clamp(0.0, 1.0);
                return Padding(
                  padding: EdgeInsets.symmetric(horizontal: _barSpacing / 2),
                  child: Container(
                    width: _barWidth,
                    height: h,
                    decoration: BoxDecoration(
                      color: AppColors.brandPrimary.withValues(alpha: alpha),
                      borderRadius: BorderRadius.circular(_barWidth / 2),
                    ),
                  ),
                );
              }),
            );
          },
        ),
      ),
    );
  }
}
