import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:provider/provider.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Dedicated full-screen pendant connection UI.
///
/// Reachable from the kebab menu (Lane E v0). Coexists with the chat-step
/// turn, status pill, connect-pendant voice card, and pairing sheet from
/// earlier lanes — none of them is removed.
///
/// **Voice card grammar does NOT apply here** — this is a Settings-style
/// screen, not a Home card. Surface containers (border + fill) are used per
/// DESIGN.md surface-card rules.
///
/// One body per [PendantState]; copy and tokens come from the design
/// system. Mirrors the same actions the pairing sheet already exposes
/// (`startPair`, `reconnect`, `openAppSettings`) and adds two screen-only
/// actions: explicit `disconnect()` (live state) and a quiet read-only
/// view for `interrupted`.
class PendantScreen extends StatelessWidget {
  const PendantScreen({super.key, this.openAppSettings});

  /// Test seam — production callers omit and we use the platform helper.
  final Future<bool> Function()? openAppSettings;

  /// Convenience constructor for callers in the kebab menu and elsewhere.
  static Route<void> route() => MaterialPageRoute(builder: (_) => const PendantScreen());

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final info = context.watch<PendantProvider>().info;

    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundPrimary,
        elevation: 0,
        title: Text(
          l.pendantScreenTitle,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
        ),
        leading: const BackButton(color: AppColors.textPrimary),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppStyles.spacingL),
          child: _bodyFor(context, info, l),
        ),
      ),
    );
  }

  Widget _bodyFor(BuildContext context, PendantInfo info, AppLocalizations l) {
    switch (info.state) {
      case PendantState.unpaired:
        return _UnpairedBody(
          ctaLabel: l.pendantScreenPairCta,
          hint: l.pendantScreenPairHint,
        );
      case PendantState.permissionDenied:
        return _PermissionDeniedBody(
          message: l.pendantPairPermissionDenied,
          ctaLabel: l.pendantPairOpenSettings,
          openAppSettings: openAppSettings ?? _openAppSettingsDefault,
        );
      case PendantState.pairing:
      case PendantState.connecting:
        return _ProgressBody(message: l.pendantPairConnecting);
      case PendantState.incompatible:
        return _IncompatibleBody(message: l.pendantPairIncompatible, ctaLabel: l.pendantPairTryAgain);
      case PendantState.live:
        return _LiveBody(info: info, l: l);
      case PendantState.reconnecting:
        return _StatusBody(
          dotColor: AppColors.warningColor,
          title: l.pendantPillReconnecting,
          showSpinner: true,
        );
      case PendantState.offline:
        return _OfflineBody(info: info, l: l);
      case PendantState.interrupted:
        return _StatusBody(
          dotColor: AppColors.textTertiary,
          title: l.pendantPillPaused,
          subtitle: l.pendantScreenInterruptedExplain,
        );
    }
  }
}

Future<bool> _openAppSettingsDefault() => ph.openAppSettings();

/// Surface card matching DESIGN.md grammar — border + fill, used wherever
/// the screen needs to delineate a content block. Pendant screen renders at
/// most one of these visible at a time (we are a settings-style screen, not
/// a Home stack).
class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppStyles.spacingL),
      decoration: BoxDecoration(
        color: AppColors.backgroundSecondary,
        borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
        border: Border.all(color: AppColors.backgroundTertiary, width: 1),
      ),
      child: child,
    );
  }
}

class _UnpairedBody extends StatelessWidget {
  const _UnpairedBody({required this.ctaLabel, required this.hint});

  final String ctaLabel;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hint,
                style: const TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.4),
              ),
              const SizedBox(height: AppStyles.spacingL),
              ElevatedButton(
                onPressed: () => context.read<PendantProvider>().startPair(),
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
        ),
      ],
    );
  }
}

class _PermissionDeniedBody extends StatelessWidget {
  const _PermissionDeniedBody({
    required this.message,
    required this.ctaLabel,
    required this.openAppSettings,
  });

  final String message;
  final String ctaLabel;
  final Future<bool> Function() openAppSettings;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: Column(
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
      ),
    );
  }
}

class _ProgressBody extends StatelessWidget {
  const _ProgressBody({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
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
    );
  }
}

class _IncompatibleBody extends StatelessWidget {
  const _IncompatibleBody({required this.message, required this.ctaLabel});

  final String message;
  final String ctaLabel;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(message, style: const TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.4)),
          const SizedBox(height: AppStyles.spacingL),
          ElevatedButton(
            onPressed: () => context.read<PendantProvider>().startPair(),
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

class _LiveBody extends StatelessWidget {
  const _LiveBody({required this.info, required this.l});

  final PendantInfo info;
  final AppLocalizations l;

  @override
  Widget build(BuildContext context) {
    final deviceName = info.deviceName ?? 'Omi pendant';
    final battery = info.batteryPercent;
    final codec = info.codec;

    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(color: AppColors.brandPrimary, shape: BoxShape.circle),
              ),
              const SizedBox(width: AppStyles.spacingS),
              Text(
                l.pendantScreenConnectedHeader,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: AppStyles.spacingM),
          Text(
            deviceName,
            style: brandEmphasis(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
          ),
          if (codec != null) ...[
            const SizedBox(height: AppStyles.spacingS),
            _CodecBadge(codecName: codec.name, label: l.pendantScreenCodecLabel(codec.name)),
          ],
          if (battery != null) ...[
            const SizedBox(height: AppStyles.spacingS),
            Row(
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
          const SizedBox(height: AppStyles.spacingL),
          OutlinedButton(
            onPressed: () => context.read<PendantProvider>().disconnect(),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              side: const BorderSide(color: AppColors.backgroundTertiary, width: 1),
              minimumSize: const Size.fromHeight(AppStyles.touchTargetMinimum),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppStyles.radiusPill)),
            ),
            child: Text(
              l.pendantScreenDisconnectCta,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _CodecBadge extends StatelessWidget {
  const _CodecBadge({required this.codecName, required this.label});

  final String codecName;
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

class _StatusBody extends StatelessWidget {
  const _StatusBody({
    required this.dotColor,
    required this.title,
    this.subtitle,
    this.showSpinner = false,
  });

  final Color dotColor;
  final String title;
  final String? subtitle;
  final bool showSpinner;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: AppStyles.spacingS),
              Text(
                title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
              ),
              if (showSpinner) ...[
                const SizedBox(width: AppStyles.spacingM),
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(AppColors.warningColor),
                  ),
                ),
              ],
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: AppStyles.spacingM),
            Text(
              subtitle!,
              style: const TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

class _OfflineBody extends StatelessWidget {
  const _OfflineBody({required this.info, required this.l});

  final PendantInfo info;
  final AppLocalizations l;

  @override
  Widget build(BuildContext context) {
    final timeLabel = _formatTime(info.offlineSince);
    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(color: AppColors.errorColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: AppStyles.spacingS),
              Expanded(
                child: Text(
                  l.pendantPillOfflineSince(timeLabel),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppStyles.spacingL),
          ElevatedButton(
            onPressed: () => context.read<PendantProvider>().reconnect(),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.brandPrimary,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(AppStyles.touchTargetMinimum),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppStyles.radiusPill)),
            ),
            child: Text(
              l.pendantScreenReconnectCta,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime? when) {
    if (when == null) return '';
    final h = when.hour.toString().padLeft(2, '0');
    final m = when.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
