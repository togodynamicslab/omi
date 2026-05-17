import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/env_flags.dart';
import 'package:nooto_v2/settings/screens/about_settings_screen.dart';
import 'package:nooto_v2/settings/screens/account_settings_screen.dart';
import 'package:nooto_v2/settings/screens/developer_settings_screen.dart';
import 'package:nooto_v2/settings/screens/native_sync_settings_screen.dart';
import 'package:nooto_v2/settings/screens/notifications_settings_screen.dart';
import 'package:nooto_v2/settings/screens/pendant_settings_screen.dart';
import 'package:nooto_v2/settings/screens/permissions_settings_screen.dart';
import 'package:nooto_v2/settings/settings_seams.dart';
import 'package:nooto_v2/settings/widgets/category_row.dart';
import 'package:nooto_v2/settings/widgets/divider.dart';
import 'package:nooto_v2/settings/widgets/surface_card.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// iOS HIG-style category browser for Settings.
///
/// Replaces the prior single-screen flat scroll. Each row pushes a focused
/// sub-page (Account, Permissions, Pendant, Notifications, About, Developer)
/// onto the root navigator. Voice-card grammar does NOT apply here — this is
/// a Settings-style screen, so we use surface cards with a grouped-list
/// layout (rows + dividers, EdgeInsets.zero on the card itself).
///
/// Search: pull-to-reveal `CupertinoSearchTextField` filters categories live
/// by label + description + keywords. Searching does not navigate; the user
/// still taps a category row.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.permissionResolver,
    this.openAppSettings,
    this.emailResolver,
    this.onResetOnboarding,
  });

  /// Test seam — production callers omit; live OS status when null.
  final PermissionResolver? permissionResolver;

  /// Test seam — production callers omit; opens iOS Settings via
  /// `permission_handler` when null.
  final Future<bool> Function()? openAppSettings;

  /// Test seam — production callers omit; reads
  /// `FirebaseAuth.instance.currentUser?.email` when null.
  final EmailResolver? emailResolver;

  /// Test seam — production callers omit; production reset path runs when
  /// null (wipes Home + Chat Hive boxes, calls `OnboardingChatProvider.reset()`).
  final Future<void> Function(BuildContext context)? onResetOnboarding;

  /// Convenience constructor for callers in the kebab menu.
  static Route<void> route() => MaterialPageRoute(builder: (_) => const SettingsScreen());

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value.trim().toLowerCase());
  }

  bool _matches(_CategoryMeta meta) {
    if (_query.isEmpty) return true;
    if (meta.label.toLowerCase().contains(_query)) return true;
    if (meta.description.toLowerCase().contains(_query)) return true;
    return meta.keywords.any((k) => k.toLowerCase().contains(_query));
  }

  List<_CategoryGroup> _groups(AppLocalizations l) {
    final groups = <_CategoryGroup>[
      _CategoryGroup([
        _CategoryMeta(
          id: _CategoryId.account,
          icon: Icons.person_outline,
          label: l.settingsCategoryAccount,
          description: l.settingsCategoryAccountDescription,
          keywords: const ['account', 'sign', 'email', 'user', 'identity', 'login', 'logout'],
          buildRoute: () => AccountSettingsScreen.route(emailResolver: widget.emailResolver),
        ),
        _CategoryMeta(
          id: _CategoryId.permissions,
          icon: Icons.lock_outline,
          label: l.settingsCategoryPermissions,
          description: l.settingsCategoryPermissionsDescription,
          keywords: const ['permissions', 'microphone', 'bluetooth', 'notifications', 'location', 'privacy'],
          buildRoute: () => PermissionsSettingsScreen.route(
            permissionResolver: widget.permissionResolver,
            openAppSettings: widget.openAppSettings,
          ),
        ),
        _CategoryMeta(
          id: _CategoryId.pendant,
          icon: Icons.bluetooth,
          label: l.settingsCategoryPendant,
          description: l.settingsCategoryPendantDescription,
          keywords: const ['pendant', 'bluetooth', 'device', 'codec', 'battery', 'omi'],
          buildRoute: () => PendantSettingsScreen.route(),
        ),
      ]),
      _CategoryGroup([
        _CategoryMeta(
          id: _CategoryId.notifications,
          icon: Icons.notifications_none,
          label: l.settingsCategoryNotifications,
          description: l.settingsCategoryNotificationsDescription,
          keywords: const ['notifications', 'push', 'inbox', 'apps', 'brief', 'alerts'],
          buildRoute: () => NotificationsSettingsScreen.route(
            permissionResolver: widget.permissionResolver,
            openAppSettings: widget.openAppSettings,
          ),
        ),
        if (kEnableProactiveRemindersPush)
          _CategoryMeta(
            id: _CategoryId.nativeSync,
            icon: Icons.checklist_rtl,
            label: l.settingsCategoryNativeSync,
            description: l.settingsCategoryNativeSyncDescription,
            keywords: const ['reminders', 'native', 'sync', 'apple', 'ios', 'auto', 'push', 'tasks'],
            buildRoute: () => NativeSyncSettingsScreen.route(),
          ),
      ]),
      _CategoryGroup([
        _CategoryMeta(
          id: _CategoryId.about,
          icon: Icons.info_outline,
          label: l.settingsCategoryAbout,
          description: l.settingsCategoryAboutDescription,
          keywords: const ['about', 'build', 'version', 'support', 'privacy', 'terms'],
          buildRoute: () => AboutSettingsScreen.route(),
        ),
      ]),
    ];

    // TODO: gate Developer category on a real `_devMode` flag. For now we
    // surface it whenever we're in a debug build, plus always to keep the
    // dogfood debug surface reachable on profile/release builds too.
    if (kDebugMode || true) {
      groups.add(
        _CategoryGroup([
          _CategoryMeta(
            id: _CategoryId.developer,
            icon: Icons.code,
            label: l.settingsCategoryDeveloper,
            description: l.settingsCategoryDeveloperDescription,
            keywords: const ['developer', 'debug', 'reset', 'onboarding', 'diagnostics'],
            buildRoute: () => DeveloperSettingsScreen.route(
              openAppSettings: widget.openAppSettings,
              onResetOnboarding: widget.onResetOnboarding,
            ),
          ),
        ]),
      );
    }

    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final groups = _groups(l);
    final filteredGroups = groups
        .map((g) => _CategoryGroup(g.items.where(_matches).toList(growable: false)))
        .where((g) => g.items.isNotEmpty)
        .toList(growable: false);
    final hasResults = filteredGroups.isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              backgroundColor: AppColors.backgroundPrimary,
              elevation: 0,
              toolbarHeight: AppStyles.touchTargetMinimum,
              title: Text(
                l.settingsScreenTitle,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
              ),
              centerTitle: true,
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppStyles.spacingL,
                  AppStyles.spacingS,
                  AppStyles.spacingL,
                  AppStyles.spacingS,
                ),
                child: CupertinoSearchTextField(
                  controller: _searchController,
                  placeholder: l.settingsSearchPlaceholder,
                  placeholderStyle: const TextStyle(color: AppColors.textTertiary, fontSize: 14),
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundSecondary,
                    borderRadius: BorderRadius.circular(AppStyles.radiusMedium),
                  ),
                  itemColor: AppColors.textTertiary,
                  onChanged: _onQueryChanged,
                ),
              ),
            ),
            if (!hasResults)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingXL, vertical: AppStyles.spacingXXL),
                  child: Center(
                    child: Text(
                      l.settingsSearchEmpty,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14, color: AppColors.textTertiary),
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppStyles.spacingL,
                  AppStyles.spacingM,
                  AppStyles.spacingL,
                  AppStyles.spacingXL,
                ),
                sliver: SliverList.separated(
                  itemCount: filteredGroups.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppStyles.spacingL),
                  itemBuilder: (ctx, groupIndex) {
                    final group = filteredGroups[groupIndex];
                    return _CategoryGroupCard(group: group);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CategoryGroupCard extends StatelessWidget {
  const _CategoryGroupCard({required this.group});

  final _CategoryGroup group;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < group.items.length; i++) {
      final item = group.items[i];
      children.add(
        SettingsCategoryRow(
          icon: item.icon,
          label: item.label,
          onTap: () {
            Navigator.of(context).push(item.buildRoute());
          },
        ),
      );
      if (i < group.items.length - 1) {
        children.add(const SettingsDivider(indent: AppStyles.spacingL + 20 + AppStyles.spacingL));
      }
    }
    return SettingsSurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(children: children),
    );
  }
}

class _CategoryGroup {
  const _CategoryGroup(this.items);

  final List<_CategoryMeta> items;
}

class _CategoryMeta {
  const _CategoryMeta({
    required this.id,
    required this.icon,
    required this.label,
    required this.description,
    required this.keywords,
    required this.buildRoute,
  });

  final _CategoryId id;
  final IconData icon;
  final String label;
  final String description;
  final List<String> keywords;
  final Route<void> Function() buildRoute;
}

enum _CategoryId { account, permissions, pendant, notifications, nativeSync, about, developer }
