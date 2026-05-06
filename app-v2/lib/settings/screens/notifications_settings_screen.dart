import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/services/api_client.dart';
import 'package:nooto_v2/services/notification_service.dart';
import 'package:nooto_v2/settings/settings_seams.dart';
import 'package:nooto_v2/settings/widgets/surface_card.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Notifications-as-chat settings sub-page.
///
/// Standard iOS-style: label left, toggle right, sub-label below describing
/// on/off + OS-permission state. When the user toggles off, the notification
/// service skips token registration on subsequent sign-ins (and re-registers
/// when toggled back on).
class NotificationsSettingsScreen extends StatefulWidget {
  const NotificationsSettingsScreen({super.key, this.permissionResolver, this.openAppSettings});

  final PermissionResolver? permissionResolver;
  final Future<bool> Function()? openAppSettings;

  static Route<void> route({PermissionResolver? permissionResolver, Future<bool> Function()? openAppSettings}) =>
      MaterialPageRoute(
        builder: (_) =>
            NotificationsSettingsScreen(permissionResolver: permissionResolver, openAppSettings: openAppSettings),
      );

  @override
  State<NotificationsSettingsScreen> createState() => _NotificationsSettingsScreenState();
}

class _NotificationsSettingsScreenState extends State<NotificationsSettingsScreen> with WidgetsBindingObserver {
  bool? _toggleEnabled;
  PermissionStatus? _osStatus;
  bool _sendingTest = false;

  PermissionResolver get _resolve => widget.permissionResolver ?? defaultPermissionResolver;
  Future<bool> Function() get _openSettings => widget.openAppSettings ?? defaultOpenAppSettings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hydrateToggle();
    _loadOsStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadOsStatus();
    }
  }

  Future<void> _hydrateToggle() async {
    final value = await context.read<NotificationService>().isToggleEnabled();
    if (!mounted) return;
    setState(() => _toggleEnabled = value);
  }

  Future<void> _loadOsStatus() async {
    final status = await _resolve(Permission.notification);
    if (!mounted) return;
    setState(() => _osStatus = status);
  }

  Future<void> _onToggleChanged(bool value) async {
    setState(() => _toggleEnabled = value);
    final service = context.read<NotificationService>();
    await service.setToggleEnabled(value);
    if (value) {
      // Re-runs the registration flow (permission request + token persist).
      // Idempotent at the backend.
      unawaited(service.onSignIn());
    }
  }

  String _resolveSubLabel(AppLocalizations l) {
    final toggle = _toggleEnabled ?? true;
    if (!toggle) return l.settingsNotificationsStateOff;
    if (_isDeniedOsSide) return l.settingsNotificationsStateOpenSettings;
    return l.settingsNotificationsStateOn;
  }

  bool get _isDeniedOsSide {
    final os = _osStatus;
    return os != null && (os.isDenied || os.isPermanentlyDenied || os.isRestricted);
  }

  Future<void> _onSendTest() async {
    if (_sendingTest) return;
    setState(() => _sendingTest = true);
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<NotificationService>().sendTestNotification();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(l.settingsNotificationsTestSent)));
    } on ApiError catch (e) {
      if (!mounted) return;
      final detail = (e.detail != null && e.detail!.isNotEmpty) ? e.detail! : 'HTTP ${e.statusCode}';
      messenger.showSnackBar(SnackBar(content: Text(detail)));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(l.settingsNotificationsTestFailed)));
    } finally {
      if (mounted) setState(() => _sendingTest = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final toggle = _toggleEnabled ?? true;
    final subLabel = _resolveSubLabel(l);
    final showOpenSettingsTap = toggle && _isDeniedOsSide;

    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundPrimary,
        elevation: 0,
        toolbarHeight: AppStyles.touchTargetMinimum,
        title: Text(
          l.settingsCategoryNotifications,
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
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.settingsNotificationsLabel,
                          style: const TextStyle(fontSize: 16, color: AppColors.textPrimary),
                        ),
                        const SizedBox(height: AppStyles.spacingXS),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: showOpenSettingsTap
                              ? () {
                                  _openSettings();
                                }
                              : null,
                          child: Text(subLabel, style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                        ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    value: toggle,
                    activeTrackColor: AppColors.brandPrimary,
                    onChanged: _toggleEnabled == null ? null : _onToggleChanged,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppStyles.spacingL),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingS),
              child: Text(
                l.settingsNotificationsDescription,
                style: const TextStyle(fontSize: 13, color: AppColors.textTertiary, height: 1.45),
              ),
            ),
            const SizedBox(height: AppStyles.spacingXL),
            SettingsSurfaceCard(
              child: InkWell(
                onTap: _sendingTest ? null : _onSendTest,
                borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
                child: SizedBox(
                  height: AppStyles.touchTargetMinimum,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l.settingsNotificationsTestAction,
                          style: const TextStyle(fontSize: 16, color: AppColors.brandPrimary),
                        ),
                      ),
                      _sendingTest
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CupertinoActivityIndicator(color: AppColors.textTertiary),
                            )
                          : const Icon(Icons.chevron_right, color: AppColors.textTertiary, size: 20),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppStyles.spacingS),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingS),
              child: Text(
                l.settingsNotificationsTestHint,
                style: const TextStyle(fontSize: 12, color: AppColors.textTertiary, height: 1.45),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
