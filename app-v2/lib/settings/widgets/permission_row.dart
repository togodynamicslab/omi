import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/settings/widgets/status_badge.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Permission label + live status badge + Open-Settings shortcut.
///
/// The whole row's right-side button respects 44pt touch target. Badge color
/// reflects current `PermissionStatus`; tapping the trailing CTA invokes
/// [onOpenSettings] which routes to the iOS app-specific Settings page.
class PermissionRow extends StatelessWidget {
  const PermissionRow({
    super.key,
    required this.label,
    required this.status,
    required this.l,
    required this.onOpenSettings,
  });

  final String label;
  final PermissionStatus? status;
  final AppLocalizations l;
  final Future<bool> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppStyles.spacingXS),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 14, color: AppColors.textPrimary)),
          ),
          StatusBadge(status: status, l: l),
          const SizedBox(width: AppStyles.spacingS),
          SizedBox(
            height: AppStyles.touchTargetMinimum,
            child: TextButton(
              onPressed: () {
                onOpenSettings();
              },
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingM),
                minimumSize: const Size(0, AppStyles.touchTargetMinimum),
              ),
              child: Text(
                l.settingsPermissionOpenSettingsCta,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.brandPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
