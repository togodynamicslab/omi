import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/settings/settings_seams.dart';
import 'package:nooto_v2/settings/widgets/divider.dart';
import 'package:nooto_v2/settings/widgets/permission_row.dart';
import 'package:nooto_v2/settings/widgets/surface_card.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Permissions sub-page: live OS status for the 4 tracked permissions.
///
/// Re-fetches statuses on resume (when the user returns from iOS Settings)
/// so the badges reflect any change they made.
class PermissionsSettingsScreen extends StatefulWidget {
  const PermissionsSettingsScreen({super.key, this.permissionResolver, this.openAppSettings});

  final PermissionResolver? permissionResolver;
  final Future<bool> Function()? openAppSettings;

  static Route<void> route({PermissionResolver? permissionResolver, Future<bool> Function()? openAppSettings}) =>
      MaterialPageRoute(
        builder: (_) =>
            PermissionsSettingsScreen(permissionResolver: permissionResolver, openAppSettings: openAppSettings),
      );

  @override
  State<PermissionsSettingsScreen> createState() => _PermissionsSettingsScreenState();
}

class _PermissionsSettingsScreenState extends State<PermissionsSettingsScreen> with WidgetsBindingObserver {
  static const List<Permission> _trackedPermissions = [
    Permission.microphone,
    Permission.bluetooth,
    Permission.notification,
    Permission.locationWhenInUse,
  ];

  final Map<Permission, PermissionStatus> _statuses = {};

  PermissionResolver get _resolve => widget.permissionResolver ?? defaultPermissionResolver;
  Future<bool> Function() get _openSettings => widget.openAppSettings ?? defaultOpenAppSettings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadStatuses();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadStatuses();
    }
  }

  Future<void> _loadStatuses() async {
    final results = await Future.wait(_trackedPermissions.map(_resolve));
    if (!mounted) return;
    setState(() {
      _statuses
        ..clear()
        ..addEntries([
          for (var i = 0; i < _trackedPermissions.length; i++) MapEntry(_trackedPermissions[i], results[i]),
        ]);
    });
  }

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
          l.settingsCategoryPermissions,
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
                children: [
                  PermissionRow(
                    label: l.settingsPermissionMicrophone,
                    status: _statuses[Permission.microphone],
                    l: l,
                    onOpenSettings: _openSettings,
                  ),
                  const SettingsDivider(),
                  PermissionRow(
                    label: l.settingsPermissionBluetooth,
                    status: _statuses[Permission.bluetooth],
                    l: l,
                    onOpenSettings: _openSettings,
                  ),
                  const SettingsDivider(),
                  PermissionRow(
                    label: l.settingsPermissionNotifications,
                    status: _statuses[Permission.notification],
                    l: l,
                    onOpenSettings: _openSettings,
                  ),
                  const SettingsDivider(),
                  PermissionRow(
                    label: l.settingsPermissionLocation,
                    status: _statuses[Permission.locationWhenInUse],
                    l: l,
                    onOpenSettings: _openSettings,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
