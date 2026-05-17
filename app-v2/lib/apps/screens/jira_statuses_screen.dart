import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/apps/jira_status_classification.dart';
import 'package:nooto_v2/apps/jira_statuses_provider.dart';
import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/services/api_client.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Sub-page of the Jira app detail screen. Lists every Jira (cloudid,
/// status_name) the user's tickets have ever touched, with the current
/// bucket (self / waiting / blocked / completed / dropped / unclassified)
/// and lets the user override the bucket via a modal bottom sheet picker.
///
/// Routed from [AppDetailScreen] only when `app.id == "nooto-jira"`. The
/// route owns its own provider so navigating away disposes the in-memory
/// list — there's no app-wide cache to invalidate.
class JiraStatusesScreen extends StatelessWidget {
  const JiraStatusesScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const JiraStatusesScreen());

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ChangeNotifierProvider<JiraStatusesProvider>(
      // ApiClient is provided app-wide in main.dart, so the lookup always
      // resolves; no fallback wiring needed. Kicks off the first fetch in
      // a microtask so the provider exists in the tree before notifyListeners.
      create: (ctx) {
        final provider = JiraStatusesProvider(client: ctx.read<ApiClient>());
        scheduleMicrotask(provider.fetchAll);
        return provider;
      },
      child: Scaffold(
        backgroundColor: AppColors.backgroundPrimary,
        appBar: AppBar(
          backgroundColor: AppColors.backgroundPrimary,
          elevation: 0,
          toolbarHeight: AppStyles.touchTargetMinimum,
          title: Text(
            l.jiraStatusesTitle,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
          ),
          centerTitle: true,
          leading: const BackButton(color: AppColors.textPrimary),
        ),
        body: const SafeArea(child: _Body()),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<JiraStatusesProvider>();
    if (provider.loading && provider.items.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: AppColors.brandPrimary, strokeWidth: 2));
    }
    if (provider.error != null && provider.items.isEmpty) {
      return _ErrorState(onRetry: provider.fetchAll);
    }
    if (provider.items.isEmpty) {
      return const _EmptyState();
    }
    return RefreshIndicator(
      color: AppColors.brandPrimary,
      backgroundColor: AppColors.backgroundSecondary,
      onRefresh: provider.fetchAll,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: AppStyles.spacingS),
        itemCount: provider.items.length,
        separatorBuilder: (_, _) => Divider(
          height: 1,
          thickness: 1,
          color: Colors.white.withValues(alpha: 0.04),
          indent: AppStyles.spacingL,
          endIndent: AppStyles.spacingL,
        ),
        itemBuilder: (ctx, i) => _StatusRow(item: provider.items[i]),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingXL),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.tune, size: 40, color: AppColors.textTertiary),
            const SizedBox(height: AppStyles.spacingM),
            Text(
              l.jiraStatusesEmptyTitle,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppStyles.spacingXS),
            Text(
              l.jiraStatusesEmptySubtitle,
              style: const TextStyle(fontSize: 14, color: AppColors.textTertiary, height: 1.4),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingXL),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: AppColors.textTertiary),
            const SizedBox(height: AppStyles.spacingM),
            Text(
              l.jiraStatusOverrideError,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppStyles.spacingM),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.brandPrimary,
                minimumSize: const Size(AppStyles.touchTargetMinimum, AppStyles.touchTargetMinimum),
              ),
              child: Text(l.inboxErrorRetry, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.item});
  final JiraStatusClassification item;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        _showBucketPicker(context, item);
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppStyles.touchTargetMinimum),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL, vertical: AppStyles.spacingM),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.statusName.isEmpty ? '—' : item.statusName,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: AppStyles.spacingXS),
                    Text(
                      _subtitle(context, item),
                      style: const TextStyle(fontSize: 14, color: AppColors.textTertiary, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppStyles.spacingM),
              _BucketChip(bucket: item.bucket),
            ],
          ),
        ),
      ),
    );
  }

  /// "N items · LLM-classified" / "N items · You overrode" / "N items · Default",
  /// optionally suffixed with " · needs your review" when [certainty] is low.
  static String _subtitle(BuildContext context, JiraStatusClassification item) {
    final l = AppLocalizations.of(context);
    final itemsLabel = l.jiraStatusItemsCount(item.matchingItemCount);
    final source = switch (item.source) {
      'llm' => l.jiraStatusSourceLlm,
      'override' => l.jiraStatusSourceOverride,
      'seed' || 'fallback' => l.jiraStatusSourceDefault,
      _ => l.jiraStatusSourceDefault,
    };
    final base = '$itemsLabel · $source';
    if (item.certainty == 'low' && item.source != 'override') {
      return '$base · ${l.jiraStatusNeedsReview}';
    }
    return base;
  }
}

class _BucketChip extends StatelessWidget {
  const _BucketChip({required this.bucket});
  final String? bucket;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (bucket == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingM, vertical: AppStyles.spacingXS),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppStyles.radiusPill),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Text(
          l.jiraStatusBucketUnclassified,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.textTertiary),
        ),
      );
    }
    final (label, color) = _styleFor(context, bucket!);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingM, vertical: AppStyles.spacingXS),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppStyles.radiusPill),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  static (String, Color) _styleFor(BuildContext context, String bucket) {
    final l = AppLocalizations.of(context);
    return switch (bucket) {
      'self' => (l.jiraStatusBucketSelf, AppColors.brandPrimary),
      'waiting' => (l.jiraStatusBucketWaiting, AppColors.warningColor),
      'blocked' => (l.jiraStatusBucketBlocked, AppColors.errorColor),
      'completed' => (l.jiraStatusBucketCompleted, AppColors.successColor),
      'dropped' => (l.jiraStatusBucketDropped, AppColors.textTertiary),
      _ => (bucket, AppColors.textTertiary),
    };
  }
}

/// Modal bottom sheet picker. Lists the 5 buckets with their long-form
/// descriptions; terminal buckets (completed, dropped) carry a "Marks as done"
/// badge so the user knows the override has plan-side consequences.
Future<void> _showBucketPicker(BuildContext context, JiraStatusClassification item) async {
  final provider = context.read<JiraStatusesProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final l = AppLocalizations.of(context);
  final selected = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.backgroundSecondary,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppStyles.radiusXLarge)),
    ),
    builder: (ctx) => _BucketPickerSheet(currentBucket: item.bucket),
  );
  if (selected == null || selected == item.bucket) return;
  final count = await provider.override(cloudid: item.cloudid, statusName: item.statusName, bucket: selected);
  if (count != null) {
    messenger.showSnackBar(
      SnackBar(content: Text(l.jiraStatusOverrideToast(count)), backgroundColor: AppColors.backgroundSecondary),
    );
  } else {
    messenger.showSnackBar(
      SnackBar(content: Text(l.jiraStatusOverrideError), backgroundColor: AppColors.backgroundSecondary),
    );
  }
}

class _BucketPickerSheet extends StatelessWidget {
  const _BucketPickerSheet({required this.currentBucket});
  final String? currentBucket;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final options = <({String bucket, String label, String desc, String? badge})>[
      (bucket: 'self', label: l.jiraStatusBucketSelf, desc: l.jiraStatusBucketSelfDesc, badge: null),
      (bucket: 'waiting', label: l.jiraStatusBucketWaiting, desc: l.jiraStatusBucketWaitingDesc, badge: null),
      (bucket: 'blocked', label: l.jiraStatusBucketBlocked, desc: l.jiraStatusBucketBlockedDesc, badge: null),
      (
        bucket: 'completed',
        label: l.jiraStatusBucketCompleted,
        desc: l.jiraStatusBucketCompletedDesc,
        badge: l.jiraStatusBucketCompletedBadge,
      ),
      (
        bucket: 'dropped',
        label: l.jiraStatusBucketDropped,
        desc: l.jiraStatusBucketDroppedDesc,
        badge: l.jiraStatusBucketDroppedBadge,
      ),
    ];
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset > 0 ? 0 : AppStyles.spacingS),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppStyles.spacingS),
            // Grab handle — standard iOS modal affordance.
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textQuaternary,
                borderRadius: BorderRadius.circular(AppStyles.radiusPill),
              ),
            ),
            const SizedBox(height: AppStyles.spacingM),
            for (final opt in options)
              _BucketOption(
                bucket: opt.bucket,
                label: opt.label,
                description: opt.desc,
                badge: opt.badge,
                selected: opt.bucket == currentBucket,
                onTap: () {
                  HapticFeedback.selectionClick();
                  Navigator.of(context).pop(opt.bucket);
                },
              ),
            const SizedBox(height: AppStyles.spacingS),
          ],
        ),
      ),
    );
  }
}

class _BucketOption extends StatelessWidget {
  const _BucketOption({
    required this.bucket,
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final String bucket;
  final String label;
  final String description;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppStyles.touchTargetMinimum),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL, vertical: AppStyles.spacingM),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          label,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: AppStyles.spacingS),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingS, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.backgroundTertiary,
                              borderRadius: BorderRadius.circular(AppStyles.radiusSmall),
                            ),
                            child: Text(
                              badge!,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppStyles.spacingXS),
                    Text(description, style: const TextStyle(fontSize: 14, color: AppColors.textTertiary, height: 1.4)),
                  ],
                ),
              ),
              const SizedBox(width: AppStyles.spacingM),
              SizedBox(
                width: 24,
                height: 24,
                child: selected
                    ? const Icon(Icons.check_circle, size: 22, color: AppColors.brandPrimary)
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
