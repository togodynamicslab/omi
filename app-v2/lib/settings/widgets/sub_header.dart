import 'package:flutter/material.dart';

import 'package:nooto_v2/theme/app_theme.dart';

/// Sub-header used inside a [SettingsSurfaceCard] to label a row group.
class SubHeader extends StatelessWidget {
  const SubHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
    );
  }
}
