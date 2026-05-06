import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:nooto_v2/inbox/inbox_message.dart';
import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// One row in the inbox feed: sender meta line above + chat-bubble below.
///
/// Card grammar — message bubble (DESIGN.md, 2026-05-06): fill-only, no
/// border, `radiusXLarge`. Differentiates from surface cards by the no-border
/// discipline.
///
/// Interactions:
/// - tap on truncated bubble → expand inline (180ms ease-out, matches
///   `CardEntrance`); tap again to collapse
/// - tap on sender meta line (avatar or name) → fires [onSenderTap]
/// - long-press on bubble → Cupertino action sheet (Copy, Share)
class InboxMessageBubble extends StatefulWidget {
  const InboxMessageBubble({super.key, required this.message, required this.onSenderTap, this.onShare});

  final InboxMessage message;

  /// Called when the user taps the avatar or sender name. Wires to
  /// `InboxProvider.setFilter(appId)` in the screen.
  final ValueChanged<String?> onSenderTap;

  /// Optional injection point for share — defaults to a no-op (system share
  /// sheet integration is deferred; copy is the v0 magic).
  final VoidCallback? onShare;

  @override
  State<InboxMessageBubble> createState() => _InboxMessageBubbleState();
}

class _InboxMessageBubbleState extends State<InboxMessageBubble> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final senderColor = m.isBrief ? AppColors.brandPrimary : AppColors.textPrimary;
    final reduceMotion = MediaQuery.of(context).disableAnimations;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppStyles.spacingL),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SenderMetaLine(
            displayName: m.sender.displayName,
            avatarUrl: m.sender.avatarUrl,
            createdAt: m.createdAt,
            color: senderColor,
            onTap: () => widget.onSenderTap(m.appId),
          ),
          const SizedBox(height: AppStyles.spacingXS),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () {
              HapticFeedback.mediumImpact();
              _showActions(context, m.text);
            },
            onTap: () {
              if (!_isTruncated(m.text)) return;
              setState(() => _expanded = !_expanded);
            },
            child: AnimatedSize(
              duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              alignment: Alignment.topLeft,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL, vertical: AppStyles.spacingM),
                decoration: BoxDecoration(
                  color: AppColors.backgroundSecondary,
                  borderRadius: BorderRadius.circular(AppStyles.radiusXLarge),
                  // Intentional no-border: see DESIGN.md "Message bubble"
                  // subgrammar (2026-05-06). Borders would collapse this into
                  // surface-card grammar.
                ),
                child: Text(
                  m.text,
                  maxLines: _expanded ? null : 3,
                  overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Cheap heuristic: 3 lines at 16pt averages ~150 chars in this column
  /// width. We over-show actions on borderline-short messages, but the cost
  /// is one tap that does nothing — acceptable.
  bool _isTruncated(String text) => text.length > 120 || '\n'.allMatches(text).length >= 3;

  void _showActions(BuildContext context, String text) {
    final l = AppLocalizations.of(context);
    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetCtx) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetCtx).pop();
              Clipboard.setData(ClipboardData(text: text));
            },
            child: Text(l.inboxBubbleCopy),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetCtx).pop();
              widget.onShare?.call();
            },
            child: Text(l.inboxBubbleShare),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(sheetCtx).pop(),
          child: Text(l.inboxBubbleCancel),
        ),
      ),
    );
  }
}

class _SenderMetaLine extends StatelessWidget {
  const _SenderMetaLine({
    required this.displayName,
    required this.avatarUrl,
    required this.createdAt,
    required this.color,
    required this.onTap,
  });

  final String displayName;
  final String? avatarUrl;
  final DateTime createdAt;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(
        children: [
          InboxAvatar(displayName: displayName, avatarUrl: avatarUrl, size: 28),
          const SizedBox(width: AppStyles.spacingS),
          Expanded(
            child: Text(
              displayName.isEmpty ? '—' : displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: color),
            ),
          ),
          const SizedBox(width: AppStyles.spacingS),
          Text(_relativeTime(context, createdAt), style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
        ],
      ),
    );
  }
}

/// Reusable circular avatar — network image when available, monogram fallback
/// otherwise. Public because the chip row reuses the same monogram grammar.
class InboxAvatar extends StatelessWidget {
  const InboxAvatar({super.key, required this.displayName, required this.avatarUrl, this.size = 28});

  final String displayName;
  final String? avatarUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = avatarUrl;
    if (url != null && url.isNotEmpty) {
      return ClipOval(
        child: CachedNetworkImage(
          imageUrl: url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorWidget: (_, _, _) => _MonogramAvatar(displayName: displayName, size: size),
          placeholder: (_, _) => _MonogramAvatar(displayName: displayName, size: size),
        ),
      );
    }
    return _MonogramAvatar(displayName: displayName, size: size);
  }
}

class _MonogramAvatar extends StatelessWidget {
  const _MonogramAvatar({required this.displayName, required this.size});

  final String displayName;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = displayName.isEmpty ? '?' : displayName.trim()[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: AppColors.backgroundSecondary, shape: BoxShape.circle),
      child: Text(
        letter,
        style: TextStyle(fontSize: size * 0.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary, height: 1.0),
      ),
    );
  }
}

String _relativeTime(BuildContext context, DateTime t) {
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inSeconds < 60) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  final locale = Localizations.localeOf(context).toString();
  return DateFormat.MMMd(locale).format(t);
}
