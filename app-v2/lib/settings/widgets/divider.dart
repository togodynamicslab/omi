import 'package:flutter/material.dart';

import 'package:nooto_v2/theme/app_theme.dart';

/// Hairline divider matching iOS grouped-list separators. 0.5pt thickness on
/// `backgroundSecondary`-fill cards. Indented from the left so the icon
/// gutter (in category rows) reads as continuous.
class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key, this.indent = 0});

  /// Left indent in logical pixels. Default 0 (full-width).
  final double indent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Container(height: 0.5, color: AppColors.backgroundPrimary),
    );
  }
}
