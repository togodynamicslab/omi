import 'package:flutter/material.dart';

import 'package:nooto_v2/theme/app_theme.dart';

/// iOS-style settings category row: monochrome icon + label + chevron.
///
/// 44pt minimum height. No colored circle behind the icon (rejected by
/// DESIGN.md anti-pattern #3) — the glyph reads on its own. Use as the
/// `child` of a [ListTile]-free row inside a [SettingsSurfaceCard] grouped
/// list. Tap target spans the full row via [InkWell] so iOS-style press
/// feedback matches the surface card.
class SettingsCategoryRow extends StatelessWidget {
  const SettingsCategoryRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final iconColor = enabled ? AppColors.textPrimary : AppColors.textQuaternary;
    final labelColor = enabled ? AppColors.textPrimary : AppColors.textQuaternary;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppStyles.touchTargetMinimum),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL, vertical: AppStyles.spacingM),
          child: Row(
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: AppStyles.spacingL),
              Expanded(
                child: Text(label, style: TextStyle(fontSize: 16, color: labelColor)),
              ),
              const Icon(Icons.chevron_right, size: 18, color: AppColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}
