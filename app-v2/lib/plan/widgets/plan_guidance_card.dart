import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/home/widgets/brief_rich_body.dart';
import 'package:nooto_v2/plan/plan_guidance_provider.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Voice-grammar guidance line at the top of the Plan tab. No chrome, direct
/// text on background — reads as the assistant speaking, mirroring the home
/// brief. Returns an empty box for `idle` / `loading` / `error` so the list
/// below is never delayed by a slow LLM call.
///
/// Inline `<plan id="..."/>` and `<ticket id="..."/>` references emitted by
/// the backend are rendered via the existing `BriefRichBody` parser, so chip
/// resolution and tap behavior are identical to the home brief.
class PlanGuidanceCard extends StatelessWidget {
  const PlanGuidanceCard({super.key});

  @override
  Widget build(BuildContext context) {
    final guidance = context.watch<PlanGuidanceProvider>();
    if (guidance.status != PlanGuidanceStatus.ready || guidance.text.isEmpty) {
      return const SizedBox.shrink();
    }
    final synthesizedAt = guidance.synthesizedAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppStyles.spacingL,
        AppStyles.spacingM,
        AppStyles.spacingL,
        AppStyles.spacingL,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BriefRichBody(
            body: guidance.text,
            style: const TextStyle(
              // 16pt to match the morning brief verbatim — both surfaces are
              // the same chief-of-staff voice, so they should read at the
              // same volume. DESIGN.md `bodyLarge`.
              fontSize: 16,
              color: AppColors.textSecondary,
              // Match the brief's chip-rich leading (1.6) so InlineRefChip pills
              // sit comfortably between sentences without crowding the prose.
              height: 1.6,
            ),
          ),
          if (synthesizedAt != null) ...[
            const SizedBox(height: AppStyles.spacingS),
            Text(
              _synthesizedAgo(synthesizedAt),
              style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
            ),
          ],
        ],
      ),
    );
  }

  /// Closes the "is this fresh?" loop. Cache TTL is 30 min, so without this
  /// label a stale entry reads as live. Mirrors `MorningBriefCard`'s helper
  /// so the two surfaces phrase freshness identically.
  String _synthesizedAgo(DateTime when) {
    final delta = DateTime.now().difference(when);
    if (delta.inMinutes < 2) return 'synthesized just now';
    if (delta.inMinutes < 60) return 'synthesized ${delta.inMinutes}m ago';
    if (delta.inHours < 6) return 'synthesized ${delta.inHours}h ago';
    final hour = when.hour;
    if (hour < 11) return 'synthesized this morning';
    if (hour < 17) return 'synthesized this afternoon';
    return 'synthesized this evening';
  }
}
