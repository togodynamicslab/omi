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

enum _TestStatus { idle, sending, sent, failed }

class _NotificationsSettingsScreenState extends State<NotificationsSettingsScreen> with WidgetsBindingObserver {
  bool? _toggleEnabled;
  PermissionStatus? _osStatus;
  _TestStatus _testStatus = _TestStatus.idle;
  String? _testError;
  Timer? _revertTimer;

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
    _revertTimer?.cancel();
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

  Widget _buildTestRowLabel(AppLocalizations l) {
    switch (_testStatus) {
      case _TestStatus.sent:
        return Text(
          l.settingsNotificationsTestSent,
          style: const TextStyle(fontSize: 16, color: AppColors.successColor, fontWeight: FontWeight.w500),
        );
      case _TestStatus.failed:
        return Text(
          l.settingsNotificationsTestFailed,
          style: const TextStyle(fontSize: 16, color: AppColors.errorColor, fontWeight: FontWeight.w500),
        );
      case _TestStatus.sending:
      case _TestStatus.idle:
        return Text(
          l.settingsNotificationsTestAction,
          style: const TextStyle(fontSize: 16, color: AppColors.brandPrimary),
        );
    }
  }

  Widget _buildTestRowTrailing() {
    switch (_testStatus) {
      case _TestStatus.sending:
        return const SizedBox(width: 18, height: 18, child: CupertinoActivityIndicator(color: AppColors.textTertiary));
      case _TestStatus.sent:
        return const Icon(Icons.check_circle, color: AppColors.successColor, size: 20);
      case _TestStatus.failed:
        return const Icon(Icons.error_outline, color: AppColors.errorColor, size: 20);
      case _TestStatus.idle:
        return const Icon(Icons.chevron_right, color: AppColors.textTertiary, size: 20);
    }
  }

  Future<void> _onSendTest() async {
    if (_testStatus == _TestStatus.sending) return;
    _revertTimer?.cancel();
    setState(() {
      _testStatus = _TestStatus.sending;
      _testError = null;
    });
    try {
      await context.read<NotificationService>().sendTestNotification();
      if (!mounted) return;
      setState(() {
        _testStatus = _TestStatus.sent;
        _testError = null;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      final detail = (e.detail != null && e.detail!.isNotEmpty) ? e.detail! : 'HTTP ${e.statusCode}';
      setState(() {
        _testStatus = _TestStatus.failed;
        _testError = detail;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testStatus = _TestStatus.failed;
        _testError = e.toString();
      });
    }
    _revertTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() {
        _testStatus = _TestStatus.idle;
        _testError = null;
      });
    });
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
                onTap: _testStatus == _TestStatus.sending ? null : _onSendTest,
                borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
                child: SizedBox(
                  height: AppStyles.touchTargetMinimum,
                  child: Row(
                    children: [
                      Expanded(child: _buildTestRowLabel(l)),
                      _buildTestRowTrailing(),
                    ],
                  ),
                ),
              ),
            ),
            if (_testError != null) ...[
              const SizedBox(height: AppStyles.spacingS),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingS),
                child: Text(
                  _testError!,
                  style: const TextStyle(fontSize: 12, color: AppColors.errorColor, height: 1.45),
                ),
              ),
            ],
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
