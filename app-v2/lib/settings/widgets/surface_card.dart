import 'package:flutter/material.dart';

import 'package:nooto_v2/theme/app_theme.dart';

/// Surface card matching DESIGN.md grammar — border + fill on
/// `backgroundSecondary`. Used by Settings + sub-pages.
///
/// Defaults to `EdgeInsets.all(spacingL)` padding for free-form content;
/// pass `padding: EdgeInsets.zero` when wrapping a list of rows that draw
/// their own dividers (the iOS grouped-list pattern).
class SettingsSurfaceCard extends StatelessWidget {
  const SettingsSurfaceCard({super.key, required this.child, this.padding = const EdgeInsets.all(AppStyles.spacingL)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.backgroundSecondary,
        borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
