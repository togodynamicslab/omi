import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nooto_v2/inbox/inbox_message_bubble.dart';
import 'package:nooto_v2/inbox/inbox_provider.dart';
import 'package:nooto_v2/l10n/gen/app_localizations.dart';
import 'package:nooto_v2/services/api_client.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Notifications-as-chat surface (v0). Reads messages from
/// `GET /v2/chat/inbox/feed` (server-side merge of integration messages +
/// Brief day-summaries) and renders them as a chat-style feed.
///
/// The InboxProvider is constructed locally — Inbox is a leaf surface, no
/// global hold-on-state. Pull-to-refresh resets the cursor; reaching 80%
/// scroll triggers `loadMore`.
class InboxScreen extends StatelessWidget {
  const InboxScreen({super.key, this.providerOverride});

  /// Test seam — production callers omit and we read [ApiClient] from
  /// Provider to construct a fresh [InboxProvider].
  final InboxProvider? providerOverride;

  static Route<void> route() => MaterialPageRoute(builder: (_) => const InboxScreen());

  @override
  Widget build(BuildContext context) {
    final override = providerOverride;
    if (override != null) {
      return ChangeNotifierProvider<InboxProvider>.value(value: override, child: const _InboxScreenView());
    }
    return ChangeNotifierProvider<InboxProvider>(
      create: (ctx) {
        final apiClient = ctx.read<ApiClient>();
        final provider = InboxProvider(client: apiClient);
        // Fire-and-forget initial fetch. Errors surface through provider.error.
        provider.refresh();
        return provider;
      },
      child: const _InboxScreenView(),
    );
  }
}

class _InboxScreenView extends StatefulWidget {
  const _InboxScreenView();

  @override
  State<_InboxScreenView> createState() => _InboxScreenViewState();
}

class _InboxScreenViewState extends State<_InboxScreenView> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final position = _scrollController.position;
    if (!position.hasContentDimensions) return;
    final threshold = position.maxScrollExtent * 0.8;
    if (position.pixels >= threshold) {
      // Provider guards against re-entry while loadingMore is active.
      context.read<InboxProvider>().loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final provider = context.watch<InboxProvider>();
    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundPrimary,
        elevation: 0,
        toolbarHeight: AppStyles.touchTargetMinimum,
        title: Text(
          l.inboxScreenTitle,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
        ),
        centerTitle: true,
        leading: const BackButton(color: AppColors.textPrimary),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _SenderFilterChips(
              senders: provider.chipSenders,
              selectedAppId: provider.selectedAppId,
              onTapAll: provider.clearFilter,
              onTapSender: (s) => provider.setFilter(s.appId),
            ),
            Expanded(child: _buildBody(context, provider, l)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, InboxProvider provider, AppLocalizations l) {
    if (provider.loading && provider.messages.isEmpty) {
      return const _SkeletonList();
    }
    if (provider.error != null && provider.messages.isEmpty) {
      return _ErrorState(title: l.inboxErrorTitle, retryLabel: l.inboxErrorRetry, onRetry: provider.refresh);
    }
    final filtered = provider.messagesFiltered;
    if (filtered.isEmpty) {
      return _EmptyState(
        title: l.inboxEmptyTitle,
        description: l.inboxEmptyDescription,
        actionLabel: l.inboxEmptyAction,
        onAction: () {
          // v0: no apps page route exists yet; ghost button is a no-op.
          // Tracked as TODO in scope; will wire when AppsScreen lands.
        },
      );
    }
    return RefreshIndicator(
      color: AppColors.brandPrimary,
      backgroundColor: AppColors.backgroundSecondary,
      onRefresh: provider.refresh,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(
          AppStyles.spacingL,
          AppStyles.spacingL,
          AppStyles.spacingL,
          AppStyles.spacingXL,
        ),
        itemCount: filtered.length + (provider.loadingMore ? 1 : 0),
        itemBuilder: (ctx, index) {
          if (index >= filtered.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: AppStyles.spacingM),
              child: Center(child: CupertinoActivityIndicator(radius: 8)),
            );
          }
          final message = filtered[index];
          return InboxMessageBubble(
            message: message,
            onSenderTap: (appId) {
              if (appId == null) {
                // Tapping Brief sender meta filters to Brief-only by clearing
                // app filter (Brief has appId == null in the feed).
                provider.clearFilter();
              } else {
                provider.setFilter(appId);
              }
            },
          );
        },
      ),
    );
  }
}

class _SenderFilterChips extends StatelessWidget {
  const _SenderFilterChips({
    required this.senders,
    required this.selectedAppId,
    required this.onTapAll,
    required this.onTapSender,
  });

  final List<InboxChipSender> senders;
  final String? selectedAppId;
  final VoidCallback onTapAll;
  final ValueChanged<InboxChipSender> onTapSender;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (senders.isEmpty) {
      // No senders yet → no filter row. Empty state below carries the
      // "connect an app" CTA, so duplicating chips here would be noise.
      return const SizedBox.shrink();
    }
    final allActive = selectedAppId == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppStyles.spacingM),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
        child: Row(
          children: [
            _Chip(label: l.inboxFilterAll, active: allActive, onTap: onTapAll),
            for (final sender in senders) ...[
              const SizedBox(width: AppStyles.spacingS),
              _Chip(
                label: sender.displayName.isEmpty ? '—' : sender.displayName,
                active: !allActive && sender.appId == selectedAppId,
                avatar: sender.appId == null
                    ? null
                    : InboxAvatar(displayName: sender.displayName, avatarUrl: sender.avatarUrl, size: 20),
                onTap: () => onTapSender(sender),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.active, required this.onTap, this.avatar});

  final String label;
  final bool active;
  final VoidCallback onTap;
  final Widget? avatar;

  @override
  Widget build(BuildContext context) {
    final fill = active ? AppColors.brandPrimary : Colors.transparent;
    final borderColor = active ? AppColors.brandPrimary : Colors.white.withValues(alpha: 0.06);
    final labelColor = active ? Colors.white : AppColors.textPrimary;
    return Semantics(
      button: true,
      selected: active,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: AppStyles.touchTargetMinimum),
          padding: EdgeInsets.symmetric(
            horizontal: avatar == null ? AppStyles.spacingL : AppStyles.spacingM,
            vertical: AppStyles.spacingS,
          ),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(AppStyles.radiusPill),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (avatar != null) ...[avatar!, const SizedBox(width: AppStyles.spacingS)],
              Text(
                label,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: labelColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SkeletonList extends StatelessWidget {
  const _SkeletonList();

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppStyles.spacingL,
        AppStyles.spacingL,
        AppStyles.spacingL,
        AppStyles.spacingXL,
      ),
      children: List.generate(4, (i) => _SkeletonRow(reduceMotion: reduceMotion)),
    );
  }
}

class _SkeletonRow extends StatefulWidget {
  const _SkeletonRow({required this.reduceMotion});

  final bool reduceMotion;

  @override
  State<_SkeletonRow> createState() => _SkeletonRowState();
}

class _SkeletonRowState extends State<_SkeletonRow> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
    if (!widget.reduceMotion) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppStyles.spacingL),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (ctx, _) {
          final t = widget.reduceMotion ? 0.55 : Tween(begin: 0.4, end: 0.7).transform(_controller.value);
          final color = AppColors.backgroundSecondary.withValues(alpha: t);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: AppStyles.spacingS),
                  Container(
                    width: 120,
                    height: 12,
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(AppStyles.radiusSmall)),
                  ),
                ],
              ),
              const SizedBox(height: AppStyles.spacingXS),
              Container(
                width: double.infinity,
                height: 56,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(AppStyles.radiusXLarge)),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.onAction,
  });

  final String title;
  final String description;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingXL),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox_outlined, size: 48, color: AppColors.textTertiary),
            const SizedBox(height: AppStyles.spacingL),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
            const SizedBox(height: AppStyles.spacingS),
            Text(
              description,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.5),
            ),
            const SizedBox(height: AppStyles.spacingL),
            SizedBox(
              height: AppStyles.touchTargetMinimum,
              child: TextButton(
                onPressed: onAction,
                child: Text(
                  actionLabel,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.brandPrimary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.title, required this.retryLabel, required this.onRetry});

  final String title;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingXL),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48, color: AppColors.textTertiary),
            const SizedBox(height: AppStyles.spacingL),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
            const SizedBox(height: AppStyles.spacingL),
            SizedBox(
              height: AppStyles.touchTargetMinimum,
              child: TextButton(
                onPressed: onRetry,
                child: Text(
                  retryLabel,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.brandPrimary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
