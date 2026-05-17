import 'package:flutter/material.dart';

import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Footer row that pairs the "synthesized Xm ago" timestamp with an
/// optional refresh affordance. Used by both the Home `MorningBriefCard`
/// and the Plan `PlanGuidanceCard` so the two voice surfaces phrase
/// freshness AND offer refresh identically.
///
/// When [onRefresh] is null the row collapses to the timestamp alone
/// (used in tests / preview contexts that don't wire a refresh callback).
/// When [isRefreshing] is true the icon swaps to a 14pt spinner so the
/// user sees their tap registered before the new brief lands.
class SynthesizedFooter extends StatelessWidget {
  const SynthesizedFooter({
    super.key,
    required this.synthesizedAt,
    this.onRefresh,
    this.isRefreshing = false,
  });

  final DateTime synthesizedAt;
  final Future<void> Function()? onRefresh;
  final bool isRefreshing;

  @override
  Widget build(BuildContext context) {
    final timestampStyle = const TextStyle(
      fontSize: 12,
      color: AppColors.textTertiary,
    );
    final refresh = onRefresh;
    if (refresh == null) {
      return Text(synthesizedAgo(synthesizedAt), style: timestampStyle);
    }
    final l10n = AppLocalizations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(synthesizedAgo(synthesizedAt), style: timestampStyle),
        const SizedBox(width: AppStyles.spacingXS),
        Semantics(
          button: true,
          label: l10n.refreshSummarySemantic,
          child: SizedBox(
            width: AppStyles.touchTargetMinimum,
            height: AppStyles.touchTargetMinimum,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppStyles.touchTargetMinimum / 2),
                onTap: isRefreshing ? null : refresh,
                child: Center(
                  child: isRefreshing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: AppColors.textTertiary,
                          ),
                        )
                      : const Icon(
                          Icons.refresh_rounded,
                          size: 16,
                          color: AppColors.textTertiary,
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Shared "synthesized Xm ago" formatter. Bigger windows (>6h) collapse to
/// time-of-day phrases ("this morning", "this afternoon", "this evening")
/// because exact minute counts past that point read as fake-precision.
String synthesizedAgo(DateTime when) {
  final delta = DateTime.now().difference(when);
  if (delta.inMinutes < 2) return 'synthesized just now';
  if (delta.inMinutes < 60) return 'synthesized ${delta.inMinutes}m ago';
  if (delta.inHours < 6) return 'synthesized ${delta.inHours}h ago';
  final hour = when.hour;
  if (hour < 11) return 'synthesized this morning';
  if (hour < 17) return 'synthesized this afternoon';
  return 'synthesized this evening';
}
