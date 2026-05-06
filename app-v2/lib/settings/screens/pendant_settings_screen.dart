import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/audio/codec.dart';
import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/providers/pendant_provider.dart';
import 'package:nooto_v2/services/ble/pendant_state.dart';
import 'package:nooto_v2/settings/widgets/key_value_row.dart';
import 'package:nooto_v2/settings/widgets/surface_card.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Pendant diagnostics sub-page: live PendantInfo snapshot rows.
///
/// Same key/value layout the founder dogfeed depends on for "is it connected,
/// what's the codec, why are packets dropping" debugging without leaving the
/// app.
class PendantSettingsScreen extends StatelessWidget {
  const PendantSettingsScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const PendantSettingsScreen());

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final info = context.watch<PendantProvider>().info;

    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundPrimary,
        elevation: 0,
        toolbarHeight: AppStyles.touchTargetMinimum,
        title: Text(
          l.settingsCategoryPendant,
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
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: _pendantRows(info)),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _pendantRows(PendantInfo info) {
    final deviceId = info.deviceId;
    final truncatedId = deviceId == null || deviceId.length <= 10
        ? (deviceId ?? '—')
        : '${deviceId.substring(0, 4)}…${deviceId.substring(deviceId.length - 4)}';
    final offlineSince = info.offlineSince;
    return [
      KeyValueRow(label: 'state', value: info.state.name),
      KeyValueRow(label: 'deviceId', value: truncatedId),
      KeyValueRow(label: 'deviceName', value: info.deviceName ?? '—'),
      KeyValueRow(label: 'codec', value: _codecName(info.codec)),
      KeyValueRow(label: 'batteryPercent', value: info.batteryPercent?.toString() ?? '—'),
      KeyValueRow(label: 'offlineSince', value: offlineSince == null ? '—' : offlineSince.toIso8601String()),
      KeyValueRow(label: 'droppedPacketsLastInterrupt', value: info.droppedPacketsLastInterrupt.toString()),
    ];
  }

  String _codecName(BleAudioCodec? codec) {
    if (codec == null) return '—';
    return codec.name;
  }
}
