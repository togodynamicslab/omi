import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/audio/codec.dart';
import 'package:nooto_v2/chat/chat_storage.dart';
import 'package:nooto_v2/env_flags.dart';
import 'package:nooto_v2/home/home_storage.dart';
import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/onboarding/onboarding_chat_provider.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/services/notification_service.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Test seam: lets widget tests inject a deterministic permission status
/// without poking platform channels. Mirrors the constructor-seam pattern
/// used by `api_client.dart` and `socket_streamer.dart`.
typedef PermissionResolver = Future<PermissionStatus> Function(Permission permission);

/// Test seam: lets widget tests bypass Firebase entirely. Returning `null`
/// means "no signed-in account" and renders the Not-signed-in copy.
typedef EmailResolver = String? Function();

Future<PermissionStatus> _defaultPermissionResolver(Permission p) => p.status;

Future<bool> _defaultOpenAppSettings() => openAppSettings();

String? _defaultEmailResolver() {
  if (!kEnableFirebaseAuth) return null;
  return FirebaseAuth.instance.currentUser?.email;
}

/// In-app settings + developer-mode debug panel.
///
/// Founder dogfood blocker: an iOS permission state can leave the app stuck
/// (microphone/Bluetooth denied permanently) and there is no in-product
/// surface that says so. This screen renders live permission statuses, a
/// pendant snapshot, the signed-in account email, and a deep link to the
/// app-specific iOS Settings page.
///
/// Reachable from the kebab menu (Lane G v0). Does NOT live in the bottom
/// nav. Voice-card grammar does NOT apply here — this is a Settings-style
/// screen, so we use surface cards (border + fill on `backgroundSecondary`
/// per DESIGN.md). Same `_SurfaceCard` pattern as [PendantScreen].
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.permissionResolver,
    this.openAppSettings,
    this.emailResolver,
    this.onResetOnboarding,
  });

  /// Test seam — production callers omit and we read live OS status.
  final PermissionResolver? permissionResolver;

  /// Test seam — production callers omit and we open iOS Settings via
  /// `permission_handler`.
  final Future<bool> Function()? openAppSettings;

  /// Test seam — production callers omit and we read
  /// `FirebaseAuth.instance.currentUser?.email`. Returning null renders the
  /// "Not signed in" row.
  final EmailResolver? emailResolver;

  /// Test seam — production callers omit and the production handler runs:
  /// wipes Hive (Home + Chat) then calls `OnboardingChatProvider.reset()`.
  /// Tests inject a stub to assert the button is wired.
  final Future<void> Function(BuildContext context)? onResetOnboarding;

  /// Convenience constructor for callers in the kebab menu.
  static Route<void> route() => MaterialPageRoute(builder: (_) => const SettingsScreen());

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  static const List<Permission> _trackedPermissions = [
    Permission.microphone,
    Permission.bluetooth,
    Permission.notification,
    Permission.locationWhenInUse,
  ];

  final Map<Permission, PermissionStatus> _statuses = {};

  PermissionResolver get _resolve => widget.permissionResolver ?? _defaultPermissionResolver;
  Future<bool> Function() get _openSettings => widget.openAppSettings ?? _defaultOpenAppSettings;

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
    // When the user returns from iOS Settings, refresh the permission rows
    // so the "Granted" / "Denied" badges reflect any change they made.
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

  String? _resolveSignedInEmail() {
    final resolver = widget.emailResolver ?? _defaultEmailResolver;
    return resolver();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final info = context.watch<PendantProvider>().info;
    final email = _resolveSignedInEmail();

    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundPrimary,
        elevation: 0,
        title: Text(
          l.settingsScreenTitle,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
        ),
        leading: const BackButton(color: AppColors.textPrimary),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppStyles.spacingL),
          children: [
            _SectionHeader(label: l.settingsDevModeHeader),
            const SizedBox(height: AppStyles.spacingM),
            _DevModeCard(
              l: l,
              statuses: _statuses,
              info: info,
              email: email,
              buildLabel: _buildLabel(),
              onOpenSettings: _openSettings,
            ),
            const SizedBox(height: AppStyles.spacingXL),
            _NotificationsCard(l: l, osStatus: _statuses[Permission.notification], onOpenSettings: _openSettings),
            const SizedBox(height: AppStyles.spacingXL),
            _ActionsCard(
              l: l,
              onOpenSettings: _openSettings,
              onResetOnboarding: widget.onResetOnboarding ?? _defaultResetOnboarding,
            ),
            const SizedBox(height: AppStyles.spacingL),
          ],
        ),
      ),
    );
  }

  /// Production reset path: wipes Home + Chat Hive boxes, then calls
  /// `OnboardingChatProvider.reset()`. Mirrors the legacy kebab-menu reset.
  Future<void> _defaultResetOnboarding(BuildContext context) async {
    final onboarding = context.read<OnboardingChatProvider>();
    await HomeBoxes.clearAll();
    await ChatBoxes.clearAll();
    await onboarding.reset();
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: AppStyles.spacingXS),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppColors.textTertiary,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// Surface card matching DESIGN.md grammar — border + fill on
/// `backgroundSecondary`. Mirrors the pattern in [PendantScreen].
class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppStyles.spacingL),
      decoration: BoxDecoration(
        color: AppColors.backgroundSecondary,
        borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
        border: Border.all(color: AppColors.backgroundTertiary, width: 1),
      ),
      child: child,
    );
  }
}

class _DevModeCard extends StatelessWidget {
  const _DevModeCard({
    required this.l,
    required this.statuses,
    required this.info,
    required this.email,
    required this.buildLabel,
    required this.onOpenSettings,
  });

  final AppLocalizations l;
  final Map<Permission, PermissionStatus> statuses;
  final PendantInfo info;
  final String? email;
  final String buildLabel;
  final Future<bool> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SubHeader(label: l.settingsPermissionsLabel),
          const SizedBox(height: AppStyles.spacingS),
          _PermissionRow(
            label: l.settingsPermissionMicrophone,
            status: statuses[Permission.microphone],
            l: l,
            onOpenSettings: onOpenSettings,
          ),
          _Divider(),
          _PermissionRow(
            label: l.settingsPermissionBluetooth,
            status: statuses[Permission.bluetooth],
            l: l,
            onOpenSettings: onOpenSettings,
          ),
          _Divider(),
          _PermissionRow(
            label: l.settingsPermissionNotifications,
            status: statuses[Permission.notification],
            l: l,
            onOpenSettings: onOpenSettings,
          ),
          _Divider(),
          _PermissionRow(
            label: l.settingsPermissionLocation,
            status: statuses[Permission.locationWhenInUse],
            l: l,
            onOpenSettings: onOpenSettings,
          ),
          const SizedBox(height: AppStyles.spacingL),
          _SubHeader(label: l.settingsPendantLabel),
          const SizedBox(height: AppStyles.spacingS),
          ..._pendantRows(),
          const SizedBox(height: AppStyles.spacingL),
          _SubHeader(label: l.settingsAuthLabel),
          const SizedBox(height: AppStyles.spacingS),
          _KeyValueRow(
            label: l.settingsAuthLabel,
            value: email == null || email!.isEmpty ? l.settingsAuthNotSignedIn : l.settingsAuthSignedInAs(email!),
          ),
          const SizedBox(height: AppStyles.spacingL),
          _SubHeader(label: l.settingsBuildLabel),
          const SizedBox(height: AppStyles.spacingS),
          _KeyValueRow(label: l.settingsBuildLabel, value: buildLabel),
        ],
      ),
    );
  }

  List<Widget> _pendantRows() {
    final deviceId = info.deviceId;
    final truncatedId = deviceId == null || deviceId.length <= 10
        ? (deviceId ?? '—')
        : '${deviceId.substring(0, 4)}…${deviceId.substring(deviceId.length - 4)}';
    final offlineSince = info.offlineSince;
    return [
      _KeyValueRow(label: 'state', value: info.state.name),
      _KeyValueRow(label: 'deviceId', value: truncatedId),
      _KeyValueRow(label: 'deviceName', value: info.deviceName ?? '—'),
      _KeyValueRow(label: 'codec', value: _codecName(info.codec)),
      _KeyValueRow(label: 'batteryPercent', value: info.batteryPercent?.toString() ?? '—'),
      _KeyValueRow(label: 'offlineSince', value: offlineSince == null ? '—' : offlineSince.toIso8601String()),
      _KeyValueRow(label: 'droppedPacketsLastInterrupt', value: info.droppedPacketsLastInterrupt.toString()),
    ];
  }

  String _codecName(BleAudioCodec? codec) {
    if (codec == null) return '—';
    return codec.name;
  }
}

class _SubHeader extends StatelessWidget {
  const _SubHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppStyles.spacingS),
      child: Divider(height: 1, thickness: 1, color: AppColors.backgroundTertiary),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.label, required this.status, required this.l, required this.onOpenSettings});

  final String label;
  final PermissionStatus? status;
  final AppLocalizations l;
  final Future<bool> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppStyles.spacingXS),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 14, color: AppColors.textPrimary)),
          ),
          _StatusBadge(status: status, l: l),
          const SizedBox(width: AppStyles.spacingS),
          SizedBox(
            height: AppStyles.touchTargetMinimum,
            child: TextButton(
              onPressed: () {
                onOpenSettings();
              },
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingM),
                minimumSize: const Size(0, AppStyles.touchTargetMinimum),
              ),
              child: Text(
                l.settingsPermissionOpenSettingsCta,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.brandPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status, required this.l});

  final PermissionStatus? status;
  final AppLocalizations l;

  @override
  Widget build(BuildContext context) {
    final (text, color) = _resolve();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingM, vertical: AppStyles.spacingXS),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppStyles.radiusPill),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  (String, Color) _resolve() {
    final s = status;
    if (s == null) return ('…', AppColors.textTertiary);
    if (s.isGranted) return (l.settingsPermissionStatusGranted, AppColors.brandPrimary);
    if (s.isPermanentlyDenied) return (l.settingsPermissionStatusPermanentlyDenied, AppColors.errorColor);
    if (s.isRestricted) return (l.settingsPermissionStatusRestricted, AppColors.textTertiary);
    if (s.isLimited) return (l.settingsPermissionStatusLimited, AppColors.warningColor);
    if (s.isDenied) return (l.settingsPermissionStatusDenied, AppColors.warningColor);
    return ('…', AppColors.textTertiary);
  }
}

class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppStyles.spacingXS),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textTertiary)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13, color: AppColors.textPrimary)),
          ),
        ],
      ),
    );
  }
}

/// Notifications-as-chat settings row. Standard iOS-style: label left,
/// toggle right, sub-label below describing on/off + OS-permission state.
/// When the user toggles off, [NotificationService] skips token registration
/// on subsequent sign-ins (and re-registers when toggled back on).
class _NotificationsCard extends StatefulWidget {
  const _NotificationsCard({required this.l, required this.osStatus, required this.onOpenSettings});

  final AppLocalizations l;
  final PermissionStatus? osStatus;
  final Future<bool> Function() onOpenSettings;

  @override
  State<_NotificationsCard> createState() => _NotificationsCardState();
}

class _NotificationsCardState extends State<_NotificationsCard> {
  bool? _toggleEnabled;

  @override
  void initState() {
    super.initState();
    _hydrateToggle();
  }

  Future<void> _hydrateToggle() async {
    final value = await context.read<NotificationService>().isToggleEnabled();
    if (!mounted) return;
    setState(() => _toggleEnabled = value);
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

  String _resolveSubLabel() {
    final l = widget.l;
    final toggle = _toggleEnabled ?? true;
    if (!toggle) return l.settingsNotificationsStateOff;
    final os = widget.osStatus;
    if (os != null && (os.isDenied || os.isPermanentlyDenied || os.isRestricted)) {
      return l.settingsNotificationsStateOpenSettings;
    }
    return l.settingsNotificationsStateOn;
  }

  bool get _isDeniedOsSide {
    final os = widget.osStatus;
    return os != null && (os.isDenied || os.isPermanentlyDenied || os.isRestricted);
  }

  @override
  Widget build(BuildContext context) {
    final toggle = _toggleEnabled ?? true;
    final subLabel = _resolveSubLabel();
    final showOpenSettingsTap = toggle && _isDeniedOsSide;

    return _SurfaceCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.l.settingsNotificationsLabel,
                  style: const TextStyle(fontSize: 16, color: AppColors.textPrimary),
                ),
                const SizedBox(height: AppStyles.spacingXS),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: showOpenSettingsTap
                      ? () {
                          widget.onOpenSettings();
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
    );
  }
}

class _ActionsCard extends StatelessWidget {
  const _ActionsCard({required this.l, required this.onOpenSettings, required this.onResetOnboarding});

  final AppLocalizations l;
  final Future<bool> Function() onOpenSettings;
  final Future<void> Function(BuildContext context) onResetOnboarding;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton(
            onPressed: () {
              onOpenSettings();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.brandPrimary,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(AppStyles.touchTargetMinimum),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppStyles.radiusPill)),
            ),
            child: Text(
              l.settingsActionOpenIosSettings,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          if (kDebugMode) ...[
            const SizedBox(height: AppStyles.spacingM),
            OutlinedButton(
              onPressed: () => onResetOnboarding(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.errorColor,
                side: const BorderSide(color: AppColors.backgroundTertiary, width: 1),
                minimumSize: const Size.fromHeight(AppStyles.touchTargetMinimum),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppStyles.radiusPill)),
              ),
              child: Text(
                l.settingsActionResetOnboarding,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
