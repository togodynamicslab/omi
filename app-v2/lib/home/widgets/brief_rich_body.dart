import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/home/home_nav.dart';
import 'package:nooto_v2/home/widgets/brief_inline_parser.dart';
import 'package:nooto_v2/home/widgets/inline_ref_chip.dart';
import 'package:nooto_v2/home/widgets/inline_ref_sheet.dart';
import 'package:nooto_v2/dev/typography_settings.dart';
import 'package:nooto_v2/library/conversations_provider.dart';
import 'package:nooto_v2/providers/action_items_provider.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Rich-text body for the morning brief. Replaces the plain `Text(card.body)`
/// — same outer style, but parsed for inline `<ticket/>`, `<person/>`, and
/// `<conversation/>` references that resolve to baseline-aligned chips.
///
/// References that can't be resolved against currently-loaded providers
/// fall through as the original tag literal — so a stale or hallucinated
/// id never produces a broken chip, and the user can still read the line.
class BriefRichBody extends StatelessWidget {
  const BriefRichBody({super.key, required this.body, required this.style});

  final String body;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final segments = parseBriefBody(body);
    final hasRefs = segments.any((s) => s is BriefRefSegment);
    // Dogfood toggle: when enabled, the prose body switches to Source Serif 4
    // (`brandAccent`) at the same size/color/height as the requested style.
    // DESIGN.md restricts the serif accent to one site today (the brief
    // greeting); the toggle exists so we can taste-test before committing.
    final useSerifBody = context.watch<TypographySettings?>()?.useSerifBody ?? false;
    final effectiveStyle = useSerifBody
        ? brandAccent(
            fontSize: style.fontSize ?? 16,
            color: style.color ?? AppColors.textSecondary,
            height: style.height,
          )
        : style;
    if (!hasRefs) {
      return Text(body, style: effectiveStyle);
    }
    // Tolerate absent providers — the card has shipped in widget tests
    // without ActionItemsProvider/ConversationsProvider in scope. Missing
    // providers degrade to "all refs unresolved", same path as a stale id.
    final actionItems = context.watch<ActionItemsProvider?>();
    final conversations = context.watch<ConversationsProvider?>();
    final homeNav = context.read<HomeNav?>();
    // Build O(1) lookup maps once per build. Replaces the prior O(n)
    // _findTicket scan; the same map serves plan refs (keyed by item.id).
    final actionItemByExternalId = actionItems == null ? const <String, ActionItem>{} : _byExternalId(actionItems);
    final actionItemById = actionItems == null ? const <String, ActionItem>{} : _byId(actionItems);
    final people = conversations == null ? const <String, _PersonRef>{} : _buildPeopleIndex(conversations);
    // Brand-emphasis style is sans-serif weight 600 with −0.2 letter spacing
    // (DESIGN.md `brandEmphasis`). We thread the surrounding prose's font
    // size + color so the emphasis run inherits paragraph metrics — only
    // weight + spacing change, keeping rhythm with body copy. When the
    // serif-body toggle is on, emphasis falls back to a heavier-weight
    // serif so the inline contrast still reads.
    final emphasisStyle = useSerifBody
        ? (effectiveStyle.copyWith(fontWeight: FontWeight.w600))
        : brandEmphasis(
            fontSize: style.fontSize ?? 16,
            color: style.color ?? AppColors.textPrimary,
            height: style.height,
          );
    final spans = <InlineSpan>[
      for (final segment in segments)
        switch (segment) {
          BriefTextSegment(:final value) => TextSpan(text: value),
          BriefEmphasisSegment(:final value) => TextSpan(text: value, style: emphasisStyle),
          BriefRefSegment(:final kind, :final id, :final title) => _resolveRef(
            context,
            kind: kind,
            id: id,
            title: title,
            actionItemByExternalId: actionItemByExternalId,
            actionItemById: actionItemById,
            conversations: conversations,
            people: people,
            homeNav: homeNav,
          ),
        },
    ];
    return Text.rich(TextSpan(style: effectiveStyle, children: spans));
  }

  InlineSpan _resolveRef(
    BuildContext context, {
    required BriefRefKind kind,
    required String id,
    required String? title,
    required Map<String, ActionItem> actionItemByExternalId,
    required Map<String, ActionItem> actionItemById,
    required ConversationsProvider? conversations,
    required Map<String, _PersonRef> people,
    required HomeNav? homeNav,
  }) {
    switch (kind) {
      case BriefRefKind.ticket:
        final item = actionItemByExternalId[id];
        if (item == null) return _fallbackSpan(kind, id, title);
        return _wrapInline(InlineRefChip.ticket(externalId: id, onTap: () => InlineRefSheet.showTicket(context, item)));
      case BriefRefKind.person:
        final person = people[personIdFor(id)];
        if (person == null) return _fallbackSpan(kind, id, title);
        return _wrapInline(
          InlineRefChip.person(
            displayName: person.displayName,
            onTap: () => InlineRefSheet.showPerson(
              context,
              displayName: person.displayName,
              conversationsCount: person.conversationsCount,
            ),
          ),
        );
      case BriefRefKind.conversation:
        final conv = conversations?.byId(id);
        if (conv == null) return _fallbackSpan(kind, id, title);
        return _wrapInline(
          InlineRefChip.conversation(title: conv.title, onTap: () => InlineRefSheet.showConversation(context, conv)),
        );
      case BriefRefKind.plan:
        // Render a chip whenever we have *some* label to show. If the id
        // resolves locally, the sheet's "Open in Plan" focuses the item;
        // if not (LLM cited a stale ULID), we chip-by-title and the sheet
        // notes the item isn't in the local store. Same visual rhythm as
        // Jira ticket chips, never a bare phrase.
        final item = actionItemById[id];
        final label = item?.description ?? title;
        if (label == null || label.isEmpty) return _fallbackSpan(kind, id, title);
        if (item == null) {
          debugPrint('[BriefRichBody] plan ref id="$id" not in local store — chipping by title');
        }
        return _wrapInline(
          InlineRefChip.plan(
            title: label,
            onTap: () => InlineRefSheet.showPlan(
              context,
              title: label,
              item: item,
              onOpenInPlan: () {
                final nav = homeNav;
                if (nav == null) return;
                nav.switchToTab(HomeNav.planTabIndex, focusItemId: item == null ? null : id);
              },
            ),
          ),
        );
    }
  }

  WidgetSpan _wrapInline(Widget child) {
    return WidgetSpan(alignment: PlaceholderAlignment.middle, baseline: TextBaseline.alphabetic, child: child);
  }

  /// Graceful fallback when an inline ref can't resolve. Three tiers:
  ///   1. LLM included a `title="..."` attribute → render the title verbatim
  ///      as inline text. The prose stays grammatical, no chip chrome, no
  ///      visible id. User loses the tap-to-act affordance but the brief
  ///      still reads naturally.
  ///   2. No title (legacy / pre-fix tag) → render the literal tag text.
  ///      Ugly but at least signals a stale ref to the developer; users see
  ///      this only if the prompt skipped the title attribute.
  /// Logged either way so we can spot stale-ref churn in dogfood.
  TextSpan _fallbackSpan(BriefRefKind kind, String id, String? title) {
    debugPrint('[BriefRichBody] unresolved ${kind.tagName} ref id="$id" title="${title ?? ''}"');
    if (title != null && title.isNotEmpty) {
      return TextSpan(text: title);
    }
    return TextSpan(text: '<${kind.tagName} id="$id"/>');
  }

  /// O(1) lookup by external id (Jira ticket id). Built once per `build`.
  Map<String, ActionItem> _byExternalId(ActionItemsProvider provider) {
    final map = <String, ActionItem>{};
    for (final item in provider.items) {
      final ext = item.externalSource;
      if (ext != null) map[ext.externalId] = item;
    }
    return map;
  }

  /// O(1) lookup by ActionItem.id (used by plan refs).
  Map<String, ActionItem> _byId(ActionItemsProvider provider) {
    final map = <String, ActionItem>{};
    for (final item in provider.items) {
      map[item.id] = item;
    }
    return map;
  }

  Map<String, _PersonRef> _buildPeopleIndex(ConversationsProvider provider) {
    final now = DateTime.now();
    final cutoff = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
    final byId = <String, _PersonRef>{};
    for (final conv in provider.items) {
      final created = conv.createdAt;
      if (created == null || created.isBefore(cutoff)) continue;
      for (final speaker in briefSpeakersIn(conv)) {
        final existing = byId[speaker.id];
        byId[speaker.id] = _PersonRef(
          displayName: existing?.displayName ?? speaker.displayName,
          conversationsCount: (existing?.conversationsCount ?? 0) + 1,
        );
      }
    }
    return byId;
  }
}

class _PersonRef {
  const _PersonRef({required this.displayName, required this.conversationsCount});
  final String displayName;
  final int conversationsCount;
}
