import 'package:flutter/material.dart';

import 'package:nooto_v2/home/widgets/brief_inline_parser.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Atlassian/Jira blue. Mirrors the dot color used in [JiraChip] so the
/// inline ticket variant reads as the same source-of-truth from a glance.
/// Plan refs deliberately split from this with `AppColors.successColor`
/// (emerald) so a brief mixing both reads two sources at a glance:
/// blue = external (Jira), green = ours (Plan).
const Color _jiraBlue = Color(0xFF2684FF);

/// Compact pill that lives inside flowing brief text via a `WidgetSpan`.
/// Four variants — ticket, person, conversation, plan — share the same outer
/// container metrics so a paragraph mixing the kinds doesn't jitter line
/// height. The leading icon/avatar is always 14pt; the label is 14pt
/// and ellipsizes at one line.
///
/// Touch target: ~24pt tall. This is below Apple HIG's 44pt minimum, the
/// same trade-off [JiraChip] documents — an inline pill cannot be 44pt
/// without breaking line height. The chip is a deliberate tap-to-explore
/// affordance, not a primary action; the canonical entry point lives on
/// the surface card below the brief.
///
/// [emphasized] variant paints a 1px `brandPrimary` border (replacing the
/// default 6%-alpha hairline) to anchor the eye on the priority-1 chip.
/// Reserved for OVERDUE or DUE-SOON-WITHIN-4H items only — see DESIGN.md.
class InlineRefChip extends StatelessWidget {
  const InlineRefChip._({
    required this.kind,
    required this.label,
    required this.leading,
    required this.onTap,
    required this.semanticsLabel,
    this.emphasized = false,
  });

  factory InlineRefChip.ticket({
    required String externalId,
    required VoidCallback onTap,
    bool emphasized = false,
  }) {
    return InlineRefChip._(
      kind: BriefRefKind.ticket,
      label: externalId,
      leading: Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(color: _jiraBlue, shape: BoxShape.circle),
      ),
      onTap: onTap,
      semanticsLabel: '$externalId, Jira ticket, double tap to open',
      emphasized: emphasized,
    );
  }

  factory InlineRefChip.person({
    required String displayName,
    required VoidCallback onTap,
    bool emphasized = false,
  }) {
    return InlineRefChip._(
      kind: BriefRefKind.person,
      label: _firstName(displayName),
      leading: _PersonAvatar(name: displayName),
      onTap: onTap,
      semanticsLabel: '$displayName, recent contact, double tap to view',
      emphasized: emphasized,
    );
  }

  factory InlineRefChip.conversation({
    required String title,
    required VoidCallback onTap,
    bool emphasized = false,
  }) {
    return InlineRefChip._(
      kind: BriefRefKind.conversation,
      label: _trimTitle(title),
      leading: const Icon(Icons.chat_bubble_outline_rounded, size: 12, color: AppColors.textTertiary),
      onTap: onTap,
      semanticsLabel: '$title, conversation, double tap to view',
      emphasized: emphasized,
    );
  }

  /// Plan reference — an action item from `ActionItemsProvider`. The label is
  /// the item title, capped at ~32 chars at a word boundary so very long
  /// user-typed descriptions don't dominate the prose. Single-line chip
  /// preserves the sentence-level pill grammar; multi-line chips read as
  /// blocks. Leading dot is emerald to read as "ours" against Jira-blue
  /// ticket variant.
  factory InlineRefChip.plan({
    required String title,
    required VoidCallback onTap,
    bool emphasized = false,
  }) {
    return InlineRefChip._(
      kind: BriefRefKind.plan,
      label: _trimTitle(title),
      leading: Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(color: AppColors.successColor, shape: BoxShape.circle),
      ),
      onTap: onTap,
      semanticsLabel: '$title, action item, double tap to open',
      emphasized: emphasized,
    );
  }

  final BriefRefKind kind;
  final String label;
  final Widget leading;
  final VoidCallback onTap;
  final String semanticsLabel;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final borderColor = emphasized
        ? AppColors.brandPrimary
        : Colors.white.withValues(alpha: 0.06);
    return Semantics(
      label: semanticsLabel,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppStyles.radiusSmall),
        onTap: onTap,
        child: Container(
          // Horizontal padding tightened from spacingS (8pt) to spacingXS (4pt)
          // on 2026-05-05 — at 8pt the chip-internal "air" combined with
          // surrounding prose punctuation read as broken typography
          // (`( WPNG-2951 ,`). Tighter padding lets chips sit flush in prose.
          padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingXS, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.backgroundTertiary,
            borderRadius: BorderRadius.circular(AppStyles.radiusSmall),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              leading,
              const SizedBox(width: AppStyles.spacingXS),
              // Flexible so the Text honors the parent's max-width constraint
              // — without it, Text takes intrinsic width and the chip overflows
              // the line on long titles. With Flexible the Text gets the
              // available width and TextOverflow.ellipsis kicks in when there's
              // genuinely no room. Stays single-line — multi-line chips read
              // as blocks in the middle of prose and break the sentence-level
              // pill grammar. Long titles are trimmed at word boundary on the
              // factory side (see `_trimTitle`).
              Flexible(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textSecondary,
                    height: 1.0,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PersonAvatar extends StatelessWidget {
  const _PersonAvatar({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final initials = briefPersonInitials(name);
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: AppColors.brandAccent, shape: BoxShape.circle),
      child: Text(
        initials,
        style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w700, color: AppColors.textPrimary, height: 1.0),
      ),
    );
  }
}

String _firstName(String fullName) {
  final trimmed = fullName.trim();
  if (trimmed.isEmpty) return 'Someone';
  final space = trimmed.indexOf(' ');
  return space < 0 ? trimmed : trimmed.substring(0, space);
}

/// Trim long action-item / conversation titles to keep the chip a sentence-
/// level pill, not a block. Cap at 32 chars at the last word boundary so we
/// never produce mid-syllable cuts ("Plan full weekly schedu…"). Below the
/// cap, render as-is. Above it, fall back to a hard char cut only when the
/// first word itself is longer than 12 chars (a single very long token).
String _trimTitle(String title) {
  final trimmed = title.trim();
  const cap = 32;
  if (trimmed.length <= cap) return trimmed;
  final lastSpace = trimmed.lastIndexOf(' ', cap);
  final cut = lastSpace >= 12 ? lastSpace : cap;
  return '${trimmed.substring(0, cut)}…';
}

/// First+last initial of a display name, uppercased. Falls back to a single
/// initial for one-word names and `?` for empty input. Shared between the
/// inline chip and the preview sheet so a person renders identically across
/// both surfaces.
String briefPersonInitials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
}

