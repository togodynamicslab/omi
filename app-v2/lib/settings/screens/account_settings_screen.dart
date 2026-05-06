import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/providers/auth_provider.dart';
import 'package:nooto_v2/settings/settings_seams.dart';
import 'package:nooto_v2/settings/widgets/key_value_row.dart';
import 'package:nooto_v2/settings/widgets/section_header.dart';
import 'package:nooto_v2/settings/widgets/surface_card.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Account category sub-page: signed-in email + sign-out action.
///
/// Sign-out delegates to [AuthChangeProvider.signOut], which already invokes
/// `notificationService.signOut()` (FCM token cleanup before Firebase signs
/// out). Do NOT add a second signOut call here.
class AccountSettingsScreen extends StatelessWidget {
  const AccountSettingsScreen({super.key, this.emailResolver});

  /// Test seam — production callers omit and we read
  /// `FirebaseAuth.instance.currentUser?.email`.
  final EmailResolver? emailResolver;

  static Route<void> route({EmailResolver? emailResolver}) =>
      MaterialPageRoute(builder: (_) => AccountSettingsScreen(emailResolver: emailResolver));

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final email = (emailResolver ?? defaultEmailResolver).call();

    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundPrimary,
        elevation: 0,
        toolbarHeight: AppStyles.touchTargetMinimum,
        title: Text(
          l.settingsCategoryAccount,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
        ),
        centerTitle: true,
        leading: const BackButton(color: AppColors.textPrimary),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppStyles.spacingL),
          children: [
            SettingsSectionHeader(label: l.settingsAuthLabel),
            SettingsSurfaceCard(
              child: KeyValueRow(
                label: l.settingsAuthLabel,
                value: email == null || email.isEmpty ? l.settingsAuthNotSignedIn : l.settingsAuthSignedInAs(email),
              ),
            ),
            const SizedBox(height: AppStyles.spacingXL),
            SizedBox(
              height: AppStyles.touchTargetMinimum,
              child: TextButton(
                onPressed: () {
                  context.read<AuthChangeProvider>().signOut();
                },
                child: Text(
                  l.settingsAccountSignOut,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.brandPrimary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
