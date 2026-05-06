import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:nooto_v2/home/widgets/inline_ref_chip.dart';
import 'package:nooto_v2/library/conversation_model.dart';
import 'package:nooto_v2/library/conversation_detail_screen.dart';
import 'package:nooto_v2/providers/action_items_provider.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Bottom-sheet preview for an inline reference tapped inside the morning
/// brief. Three variants share the same shell (rounded top, drag handle,
/// safe-area padding) — the body switches by entity type. Resolved entities
/// are passed in directly; the sheet does not re-fetch.
///
/// Mirrors the rounded + drag-handle grammar from
/// [showSessionActionsSheet] (`lib/chat/widgets/session_actions_sheet.dart`)
/// and [SummarizedAppsBottomSheet]
/// (`lib/library/widgets/summarized_apps_sheet.dart`).
class InlineRefSheet {
  const InlineRefSheet._();

  static Future<void> showTicket(BuildContext context, ActionItem item) {
    return _open(context, child: _TicketSheet(item: item));
  }

  static Future<void> showPerson(BuildContext context, {required String displayName, required int conversationsCount}) {
    return _open(
      context,
      child: _PersonSheet(displayName: displayName, conversationsCount: conversationsCount),
    );
  }

  static Future<void> showConversation(BuildContext context, ConversationItem conversation) {
    return _open(context, child: _ConversationSheet(conversation: conversation));
  }

  /// Plan ref preview. [item] is non-null when the brief's id resolved
  /// against `ActionItemsProvider`; null when the LLM cited a stale id and
  /// we're rendering from the title attribute alone. [onOpenInPlan] runs
  /// after the sheet pops — typically `homeNav.switchToTab(planTab, …)`.
  static Future<void> showPlan(
    BuildContext context, {
    required String title,
    ActionItem? item,
    required VoidCallback onOpenInPlan,
  }) {
    return _open(context, child: _PlanSheet(title: title, item: item, onOpenInPlan: onOpenInPlan));
  }

  static Future<void> _open(BuildContext context, {required Widget child}) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.backgroundSecondary,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppStyles.radiusXLarge)),
      ),
      builder: (_) => child,
    );
  }
}

class _SheetShell extends StatelessWidget {
  const _SheetShell({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: AppStyles.spacingS, bottom: AppStyles.spacingM),
              decoration: BoxDecoration(
                color: AppColors.textTertiary.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          ...children,
          const SizedBox(height: AppStyles.spacingL),
        ],
      ),
    );
  }
}

class _TicketSheet extends StatelessWidget {
  const _TicketSheet({required this.item});

  final ActionItem item;

  @override
  Widget build(BuildContext context) {
    final source = item.externalSource;
    final status = source?.jiraStatus;
    final project = source?.jiraProjectKey;
    final priority = source?.jiraPriority;
    return _SheetShell(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (source != null) _IdBadge(externalId: source.externalId),
              if (source != null) const SizedBox(height: AppStyles.spacingM),
              Text(
                item.description,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: AppStyles.spacingM),
              Wrap(
                spacing: AppStyles.spacingS,
                runSpacing: AppStyles.spacingS,
                children: [
                  if (project != null && project.isNotEmpty) _Pill(label: project),
                  if (status != null && status.isNotEmpty) _Pill(label: status),
                  if (priority != null && priority.isNotEmpty && _showPriority(priority)) _Pill(label: priority),
                ],
              ),
            ],
          ),
        ),
        if (source != null) ...[
          const SizedBox(height: AppStyles.spacingL),
          _PrimaryAction(
            icon: Icons.open_in_new_rounded,
            label: 'Open in Jira',
            onTap: () async {
              Navigator.of(context).pop();
              try {
                await launchUrl(Uri.parse(source.url), mode: LaunchMode.externalApplication);
              } catch (_) {
                // Same swallow as JiraChip — the user can still see the id.
              }
            },
          ),
        ],
      ],
    );
  }

  /// Hides the noisy default Jira priorities — same rule the Plan row uses.
  bool _showPriority(String value) {
    final lower = value.toLowerCase();
    return lower != 'medium' && lower != 'none' && lower.isNotEmpty;
  }
}

class _PersonSheet extends StatelessWidget {
  const _PersonSheet({required this.displayName, required this.conversationsCount});

  final String displayName;
  final int conversationsCount;

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: AppColors.brandAccent,
                child: Text(
                  briefPersonInitials(displayName),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                ),
              ),
              const SizedBox(width: AppStyles.spacingM),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitleFor(conversationsCount),
                      style: const TextStyle(fontSize: 13, color: AppColors.textTertiary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _subtitleFor(int count) {
    if (count <= 0) return 'Recent contact';
    if (count == 1) return '1 recent conversation';
    return '$count recent conversations';
  }
}

class _PlanSheet extends StatelessWidget {
  const _PlanSheet({required this.title, required this.item, required this.onOpenInPlan});

  final String title;
  final ActionItem? item;
  final VoidCallback onOpenInPlan;

  @override
  Widget build(BuildContext context) {
    final resolved = item;
    final dueAt = resolved?.dueAt;
    final completed = resolved?.completed ?? false;
    return _SheetShell(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _PlanBadge(),
              const SizedBox(height: AppStyles.spacingM),
              Text(
                resolved?.description ?? title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                  height: 1.3,
                ),
              ),
              if (resolved == null) ...[
                const SizedBox(height: AppStyles.spacingS),
                const Text(
                  'Not in your local plan yet — open Plan to find or add it.',
                  style: TextStyle(fontSize: 13, color: AppColors.textTertiary, height: 1.4),
                ),
              ],
              if (resolved != null) ...[
                const SizedBox(height: AppStyles.spacingM),
                Wrap(
                  spacing: AppStyles.spacingS,
                  runSpacing: AppStyles.spacingS,
                  children: [
                    if (completed) const _Pill(label: 'Done'),
                    if (!completed && dueAt != null) _Pill(label: _dueLabel(dueAt)),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppStyles.spacingL),
        _PrimaryAction(
          icon: Icons.arrow_forward_rounded,
          label: 'Open in Plan',
          onTap: () {
            Navigator.of(context).pop();
            onOpenInPlan();
          },
        ),
      ],
    );
  }

  /// Same overdue / due-today / due-soon vocabulary the Plan tab uses, kept
  /// short so it fits in a sheet pill.
  String _dueLabel(DateTime due) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dueDay = DateTime(due.year, due.month, due.day);
    final diff = dueDay.difference(today).inDays;
    if (diff < 0) return 'Overdue';
    if (diff == 0) return 'Due today';
    if (diff == 1) return 'Due tomorrow';
    if (diff <= 6) return 'Due in $diff days';
    return 'Due ${DateFormat('MMM d').format(due)}';
  }
}

class _PlanBadge extends StatelessWidget {
  const _PlanBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingS, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.backgroundTertiary,
        borderRadius: BorderRadius.circular(AppStyles.radiusSmall),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(color: AppColors.successColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppStyles.spacingXS),
          const Text(
            'PLAN',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConversationSheet extends StatelessWidget {
  const _ConversationSheet({required this.conversation});

  final ConversationItem conversation;

  @override
  Widget build(BuildContext context) {
    final created = conversation.createdAt;
    final overview = conversation.overview.trim();
    return _SheetShell(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                conversation.title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                  height: 1.3,
                ),
              ),
              if (created != null) ...[
                const SizedBox(height: AppStyles.spacingXS),
                Text(
                  DateFormat('EEEE, MMM d · h:mm a').format(created),
                  style: const TextStyle(fontSize: 13, color: AppColors.textTertiary),
                ),
              ],
              if (overview.isNotEmpty) ...[
                const SizedBox(height: AppStyles.spacingM),
                Text(
                  overview,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.4),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppStyles.spacingL),
        _PrimaryAction(
          icon: Icons.arrow_forward_rounded,
          label: 'Open conversation',
          onTap: () {
            Navigator.of(context).pop();
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => ConversationDetailScreen(item: conversation)));
          },
        ),
      ],
    );
  }
}

class _IdBadge extends StatelessWidget {
  const _IdBadge({required this.externalId});
  final String externalId;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingS, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.backgroundTertiary,
        borderRadius: BorderRadius.circular(AppStyles.radiusSmall),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Text(
        externalId,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppColors.textSecondary,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingS, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.backgroundTertiary,
        borderRadius: BorderRadius.circular(AppStyles.radiusSmall),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.textSecondary),
      ),
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: AppStyles.spacingM),
          decoration: BoxDecoration(
            color: AppColors.brandPrimary,
            borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: AppColors.textPrimary),
              const SizedBox(width: AppStyles.spacingS),
              Text(
                label,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
