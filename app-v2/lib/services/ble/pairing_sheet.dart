import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:provider/provider.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Modal bottom sheet shown when the user taps the onboarding turn's "Pair"
/// CTA, the offline status pill, or the connect-pendant voice card.
///
/// Visual grammar (mirrors `chat/widgets/session_actions_sheet.dart`):
///   - background `AppColors.backgroundTertiary`
///   - top corners `AppStyles.radiusLarge` (12pt)
///   - drag handle 36×4pt at `AppStyles.spacingXS` from top
///   - drag-to-dismiss only — no close button
///
/// Three rendering modes by `PendantState`:
///   - `unpaired` / `pairing` (early): scan list of nearby pendants
///   - `pairing` (mid) / `connecting`: spinner + first-connect copy
///   - `incompatible`: error message + Try Again CTA
///   - `permissionDenied`: error message + Open Settings CTA
class PairingSheet extends StatelessWidget {
  const PairingSheet({super.key, this.openAppSettings});

  /// Test seam — production callers omit and we use the platform helper.
  final Future<bool> Function()? openAppSettings;

  /// Show the pairing sheet. Drag-to-dismiss only.
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.backgroundTertiary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppStyles.radiusLarge)),
      ),
      useSafeArea: true,
      isScrollControlled: false,
      enableDrag: true,
      builder: (sheetContext) => const PairingSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final info = context.watch<PendantProvider>().info;
    final l = AppLocalizations.of(context);

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: AppStyles.spacingL,
          right: AppStyles.spacingL,
          top: AppStyles.spacingXS,
          bottom: AppStyles.spacingL,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DragHandle(),
            const SizedBox(height: AppStyles.spacingM),
            Text(
              l.pendantPairTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
            const SizedBox(height: AppStyles.spacingL),
            _bodyFor(context, info.state, l),
          ],
        ),
      ),
    );
  }

  Widget _bodyFor(BuildContext context, PendantState state, AppLocalizations l) {
    switch (state) {
      case PendantState.permissionDenied:
        return _PermissionDeniedBody(
          message: l.pendantPairPermissionDenied,
          ctaLabel: l.pendantPairOpenSettings,
          openAppSettings: openAppSettings ?? openAppSettingsDefault,
        );
      case PendantState.incompatible:
        return _IncompatibleBody(message: l.pendantPairIncompatible, ctaLabel: l.pendantPairTryAgain);
      case PendantState.pairing:
      case PendantState.connecting:
        return _ConnectingBody(message: l.pendantPairConnecting);
      case PendantState.unpaired:
      case PendantState.live:
      case PendantState.reconnecting:
      case PendantState.offline:
      case PendantState.interrupted:
        // Default scan-list view — kicks off pairing on tap. The provider
        // owns scan-result streaming; until Lane C lands we render the
        // single-action "Pair" CTA so the sheet is functional from day one.
        return _ScanListBody();
    }
  }
}

/// Default app-settings opener. Wrapped here so tests can substitute a fake
/// without pulling permission_handler into the test process.
Future<bool> openAppSettingsDefault() => ph.openAppSettings();

class _DragHandle extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.textTertiary.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _ConnectingBody extends StatelessWidget {
  const _ConnectingBody({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Setting up your pendant. This usually takes about ten seconds.',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppStyles.spacingL),
        child: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(AppColors.brandPrimary),
              ),
            ),
            const SizedBox(width: AppStyles.spacingM),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 14, color: AppColors.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }
}

class _IncompatibleBody extends StatelessWidget {
  const _IncompatibleBody({required this.message, required this.ctaLabel});

  final String message;
  final String ctaLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: "This pendant doesn't expose Omi audio. Make sure your firmware is up to date. Double-tap to retry.",
      button: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(message, style: const TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.4)),
          const SizedBox(height: AppStyles.spacingL),
          ElevatedButton(
            onPressed: () {
              context.read<PendantProvider>().startPair();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.brandPrimary,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(AppStyles.touchTargetMinimum),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppStyles.radiusPill)),
            ),
            child: Text(ctaLabel, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

class _PermissionDeniedBody extends StatelessWidget {
  const _PermissionDeniedBody({required this.message, required this.ctaLabel, required this.openAppSettings});

  final String message;
  final String ctaLabel;
  final Future<bool> Function() openAppSettings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(message, style: const TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.4)),
        const SizedBox(height: AppStyles.spacingL),
        ElevatedButton(
          onPressed: () {
            openAppSettings();
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.brandPrimary,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(AppStyles.touchTargetMinimum),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppStyles.radiusPill)),
          ),
          child: Text(ctaLabel, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _ScanListBody extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // v0 ships with a single primary "Pair" CTA. Lane C extends this
        // with a live scan-results list; the public sheet API doesn't move.
        ElevatedButton(
          onPressed: () {
            context.read<PendantProvider>().startPair();
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.brandPrimary,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(AppStyles.touchTargetMinimum),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppStyles.radiusPill)),
          ),
          child: const Text('Pair', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
