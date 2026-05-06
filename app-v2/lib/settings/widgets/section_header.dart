import 'package:flutter/material.dart';

import 'package:nooto_v2/theme/app_theme.dart';

/// Tiny uppercase eyebrow used above grouped list cards in Settings sub-pages.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: AppStyles.spacingXS, bottom: AppStyles.spacingS),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppColors.textTertiary,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}
