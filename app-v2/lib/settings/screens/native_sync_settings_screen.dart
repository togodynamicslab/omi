import 'package:flutter/material.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/proactive/proactive_push_prefs.dart';
import 'package:nooto_v2/proactive/proactive_push_storage.dart';
import 'package:nooto_v2/settings/widgets/section_header.dart';
import 'package:nooto_v2/settings/widgets/surface_card.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Settings sub-page for the proactive iOS Reminders push.
///
/// Three knobs:
///   * Master toggle — flipping ON also stamps the first-seen activation
///     anchor (see [ProactivePushPrefs.stampFirstSeenNow]) so existing open
///     items don't back-fill into Reminders.
///   * Confidence threshold — slider 0..1 in 0.05 steps.
///   * Daily budget — stepper 1..30 items/day.
///
/// Plus a "Recently pushed" row that pushes into a list view of every
/// `pushed` row in the Hive log, sorted by ts desc.
class NativeSyncSettingsScreen extends StatefulWidget {
  const NativeSyncSettingsScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const NativeSyncSettingsScreen());

  @override
  State<NativeSyncSettingsScreen> createState() => _NativeSyncSettingsScreenState();
}

class _NativeSyncSettingsScreenState extends State<NativeSyncSettingsScreen> {
  late bool _enabled;
  late double _threshold;
  late int _budget;

  @override
  void initState() {
    super.initState();
    _enabled = ProactivePushPrefs.enabled;
    _threshold = ProactivePushPrefs.confidenceThreshold;
    _budget = ProactivePushPrefs.dailyBudget;
  }

  Future<void> _setEnabled(bool value) async {
    await ProactivePushPrefs.setEnabled(value);
    if (value && ProactivePushPrefs.firstSeenAt == null) {
      // Stamp on opt-in so we don't push existing open items the next time
      // ActionItemsProvider broadcasts. The service also stamps lazily, but
      // doing it here gives a tighter UX guarantee.
      await ProactivePushPrefs.stampFirstSeenNow();
    }
    if (mounted) setState(() => _enabled = value);
  }

  Future<void> _setThreshold(double value) async {
    final clamped = (value * 20).round() / 20.0;
    await ProactivePushPrefs.setConfidenceThreshold(clamped);
    if (mounted) setState(() => _threshold = clamped);
  }

  Future<void> _setBudget(int delta) async {
    final next = (_budget + delta).clamp(1, 30);
    await ProactivePushPrefs.setDailyBudget(next);
    if (mounted) setState(() => _budget = next);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundPrimary,
        elevation: 0,
        title: Text(
          l.nativeSyncScreenTitle,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppStyles.spacingL,
          AppStyles.spacingL,
          AppStyles.spacingL,
          AppStyles.spacingXL,
        ),
        children: [
          SettingsSurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l.nativeSyncEnabledLabel,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    Switch.adaptive(value: _enabled, onChanged: _setEnabled),
                  ],
                ),
                const SizedBox(height: AppStyles.spacingS),
                Text(
                  l.nativeSyncEnabledDescription,
                  style: const TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppStyles.spacingL),
          SettingsSectionHeader(label: l.nativeSyncThresholdLabel),
          Opacity(
            opacity: _enabled ? 1.0 : 0.5,
            child: SettingsSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l.nativeSyncThresholdLabel,
                          style: const TextStyle(fontSize: 16, color: AppColors.textPrimary),
                        ),
                      ),
                      Text(
                        '${(_threshold * 100).round()}%',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  Slider.adaptive(
                    value: _threshold,
                    min: 0.0,
                    max: 1.0,
                    divisions: 20,
                    onChanged: _enabled ? _setThreshold : null,
                  ),
                  Text(
                    l.nativeSyncThresholdHelp,
                    style: const TextStyle(fontSize: 12, color: AppColors.textTertiary, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppStyles.spacingL),
          SettingsSectionHeader(label: l.nativeSyncDailyBudgetLabel),
          Opacity(
            opacity: _enabled ? 1.0 : 0.5,
            child: SettingsSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l.nativeSyncDailyBudgetLabel,
                          style: const TextStyle(fontSize: 16, color: AppColors.textPrimary),
                        ),
                      ),
                      IconButton(
                        onPressed: _enabled && _budget > 1 ? () => _setBudget(-1) : null,
                        icon: const Icon(Icons.remove_circle_outline, color: AppColors.textPrimary),
                      ),
                      SizedBox(
                        width: 32,
                        child: Text(
                          '$_budget',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _enabled && _budget < 30 ? () => _setBudget(1) : null,
                        icon: const Icon(Icons.add_circle_outline, color: AppColors.textPrimary),
                      ),
                    ],
                  ),
                  Text(
                    l.nativeSyncDailyBudgetHelp,
                    style: const TextStyle(fontSize: 12, color: AppColors.textTertiary, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppStyles.spacingL),
          SettingsSurfaceCard(
            padding: EdgeInsets.zero,
            child: ListTile(
              title: Text(
                l.nativeSyncRecentlyPushedLabel,
                style: const TextStyle(fontSize: 16, color: AppColors.textPrimary),
              ),
              trailing: const Icon(Icons.chevron_right, color: AppColors.textTertiary),
              onTap: () => Navigator.of(context).push(_RecentlyPushedScreen.route()),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentlyPushedScreen extends StatelessWidget {
  const _RecentlyPushedScreen();

  static Route<void> route() => MaterialPageRoute(builder: (_) => const _RecentlyPushedScreen());

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final rows = ProactivePushBoxes.allSortedDesc();
    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundPrimary,
        elevation: 0,
        title: Text(
          l.nativeSyncRecentlyPushedTitle,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
        ),
        centerTitle: true,
      ),
      body: rows.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(AppStyles.spacingXL),
                child: Text(
                  l.nativeSyncRecentlyPushedEmpty,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, color: AppColors.textTertiary),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                AppStyles.spacingL,
                AppStyles.spacingL,
                AppStyles.spacingL,
                AppStyles.spacingXL,
              ),
              itemCount: rows.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppStyles.spacingS),
              itemBuilder: (_, i) {
                final row = rows[i];
                final description = row.description ?? row.actionItemId;
                final state = row.kind == ProactivePushKind.userDeleted
                    ? '· user deleted in Reminders'
                    : row.confidence != null
                        ? '· ${(row.confidence! * 100).round()}% confidence'
                        : '';
                return SettingsSurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        description,
                        style: const TextStyle(fontSize: 15, color: AppColors.textPrimary, height: 1.3),
                      ),
                      const SizedBox(height: AppStyles.spacingXS),
                      Text(
                        '${row.ts.toLocal()} $state',
                        style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
