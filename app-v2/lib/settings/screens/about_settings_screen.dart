import 'package:flutter/material.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/settings/widgets/key_value_row.dart';
import 'package:nooto_v2/settings/widgets/surface_card.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// About sub-page: build version row. Placeholder for future support /
/// privacy policy / terms links.
class AboutSettingsScreen extends StatelessWidget {
  const AboutSettingsScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const AboutSettingsScreen());

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundPrimary,
        elevation: 0,
        toolbarHeight: AppStyles.touchTargetMinimum,
        title: Text(
          l.settingsCategoryAbout,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
        ),
        centerTitle: true,
        leading: const BackButton(color: AppColors.textPrimary),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppStyles.spacingL),
          children: [
            SettingsSurfaceCard(
              child: KeyValueRow(label: l.settingsBuildLabel, value: _buildLabel()),
            ),
          ],
        ),
      ),
    );
  }

  String _buildLabel() {
    // package_info_plus is intentionally not in pubspec — read from
    // compile-time env vars supplied by Flutter when available, fall back
    // to a placeholder otherwise.
    const name = String.fromEnvironment('FLUTTER_BUILD_NAME', defaultValue: '');
    const number = String.fromEnvironment('FLUTTER_BUILD_NUMBER', defaultValue: '');
    if (name.isEmpty && number.isEmpty) return '—';
    if (number.isEmpty) return name;
    if (name.isEmpty) return '($number)';
    return '$name ($number)';
  }
}
