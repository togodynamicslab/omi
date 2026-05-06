import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/chat/chat_storage.dart';
import 'package:nooto_v2/dev/typography_settings.dart';
import 'package:nooto_v2/home/home_storage.dart';
import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/onboarding/onboarding_chat_provider.dart';
import 'package:nooto_v2/settings/settings_seams.dart';
import 'package:nooto_v2/settings/widgets/surface_card.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Developer sub-page: reset onboarding + open iOS Settings shortcut.
///
/// Future home for any debug toggles. TODO: gate this whole sub-page +
/// category row on a `_devMode` flag once we add one (today render
/// unconditionally to keep the dogfood debug surface reachable).
class DeveloperSettingsScreen extends StatelessWidget {
  const DeveloperSettingsScreen({super.key, this.openAppSettings, this.onResetOnboarding});

  /// Test seam — production callers omit and we open iOS Settings via
  /// `permission_handler`.
  final Future<bool> Function()? openAppSettings;

  /// Test seam — production callers omit and the production handler runs:
  /// wipes Hive (Home + Chat) then calls `OnboardingChatProvider.reset()`.
  final Future<void> Function(BuildContext context)? onResetOnboarding;

  static Route<void> route({
    Future<bool> Function()? openAppSettings,
    Future<void> Function(BuildContext context)? onResetOnboarding,
  }) => MaterialPageRoute(
    builder: (_) => DeveloperSettingsScreen(openAppSettings: openAppSettings, onResetOnboarding: onResetOnboarding),
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final openSettings = openAppSettings ?? defaultOpenAppSettings;
    final resetOnboarding = onResetOnboarding ?? _defaultResetOnboarding;

    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundPrimary,
        elevation: 0,
        toolbarHeight: AppStyles.touchTargetMinimum,
        title: Text(
          l.settingsCategoryDeveloper,
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ElevatedButton(
                    onPressed: () {
                      openSettings();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brandPrimary,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(AppStyles.touchTargetMinimum),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppStyles.radiusPill)),
                    ),
                    child: Text(
                      l.settingsDeveloperOpenSystemSettings,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(height: AppStyles.spacingM),
                  OutlinedButton(
                    onPressed: () => resetOnboarding(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.errorColor,
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.06), width: 1),
                      minimumSize: const Size.fromHeight(AppStyles.touchTargetMinimum),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppStyles.radiusPill)),
                    ),
                    child: Text(
                      l.settingsDeveloperResetOnboarding,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppStyles.spacingL),
            const SettingsSurfaceCard(child: _SerifBriefBodyToggle()),
          ],
        ),
      ),
    );
  }

  Future<void> _defaultResetOnboarding(BuildContext context) async {
    final onboarding = context.read<OnboardingChatProvider>();
    await HomeBoxes.clearAll();
    await ChatBoxes.clearAll();
    await onboarding.reset();
  }
}

/// Toggle for the dogfood serif-body experiment. Lives here (Settings →
/// Developer) instead of the AppBar kebab so it's discoverable in the right
/// taxonomy — the kebab is for global quick actions, prefs belong here.
/// Tolerates an absent provider so the screen renders in widget tests
/// without forcing every test to install TypographySettings.
class _SerifBriefBodyToggle extends StatelessWidget {
  const _SerifBriefBodyToggle();

  @override
  Widget build(BuildContext context) {
    final typography = context.watch<TypographySettings?>();
    final enabled = typography?.useSerifBody ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingM, vertical: AppStyles.spacingXS),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Serif brief body',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: AppColors.textPrimary),
                ),
                SizedBox(height: 2),
                Text(
                  'Render brief and plan-guidance prose in Source Serif 4 instead of sans.',
                  style: TextStyle(fontSize: 13, color: AppColors.textTertiary, height: 1.3),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppStyles.spacingM),
          Switch.adaptive(
            value: enabled,
            onChanged: typography == null ? null : (v) => typography.setUseSerifBody(v),
            activeThumbColor: AppColors.brandPrimary,
          ),
        ],
      ),
    );
  }
}
