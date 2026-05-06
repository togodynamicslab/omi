import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Pill-shaped permission status badge — Granted / Denied / Restricted /
/// Limited / Permanently denied. Maps each state to a brand-or-semantic
/// color with 15% alpha fill.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status, required this.l});

  final PermissionStatus? status;
  final AppLocalizations l;

  @override
  Widget build(BuildContext context) {
    final (text, color) = _resolve();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingM, vertical: AppStyles.spacingXS),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppStyles.radiusPill),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  (String, Color) _resolve() {
    final s = status;
    if (s == null) return ('…', AppColors.textTertiary);
    if (s.isGranted) return (l.settingsPermissionStatusGranted, AppColors.brandPrimary);
    if (s.isPermanentlyDenied) return (l.settingsPermissionStatusPermanentlyDenied, AppColors.errorColor);
    if (s.isRestricted) return (l.settingsPermissionStatusRestricted, AppColors.textTertiary);
    if (s.isLimited) return (l.settingsPermissionStatusLimited, AppColors.warningColor);
    if (s.isDenied) return (l.settingsPermissionStatusDenied, AppColors.warningColor);
    return ('…', AppColors.textTertiary);
  }
}
