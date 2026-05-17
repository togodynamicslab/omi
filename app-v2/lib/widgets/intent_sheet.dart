import 'package:flutter/material.dart';

import 'package:nooto_v2/services/intents/intent_bridge.dart';
import 'package:nooto_v2/services/intents/intent_models.dart';
import 'package:nooto_v2/theme/app_theme.dart';

/// Modal sheet that wraps the on-device intent parser.
///
/// Flow:
///   1. On open, ping `IntentBridge.checkAvailability()` to confirm
///      Apple Intelligence is usable. If not, show the reason and disable
///      the input.
///   2. User types a natural-language request ("wake me at 7am",
///      "lunch at noon", "remind me to buy milk").
///   3. Tap Run → calls `parseAndDispatch`. Spinner while the LLM is
///      working (1–3s cold, ~500ms warm).
///   4. Result panel shows parsed JSON, dispatch outcome (success / no-op /
///      failed), and the LLM latency in ms.
///
/// Strings are hardcoded English for now — the integration is being
/// dogfooded before l10n keys are introduced.
class IntentSheet {
  const IntentSheet._();

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.backgroundPrimary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppStyles.radiusXLarge)),
      ),
      builder: (_) => const _Body(),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  late final IntentBridge _bridge;
  final TextEditingController _controller = TextEditingController();

  IntentAvailability? _availability;
  bool _isRunning = false;
  IntentResult? _lastResult;

  @override
  void initState() {
    super.initState();
    _bridge = IntentBridge();
    _bridge.checkAvailability().then((a) {
      if (!mounted) return;
      setState(() => _availability = a);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isRunning) return;
    setState(() {
      _isRunning = true;
      _lastResult = null;
    });
    final result = await _bridge.parseAndDispatch(text);
    if (!mounted) return;
    setState(() {
      _isRunning = false;
      _lastResult = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final availability = _availability;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppStyles.spacingL,
            AppStyles.spacingM,
            AppStyles.spacingL,
            AppStyles.spacingL,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _grabber(),
              const SizedBox(height: AppStyles.spacingM),
              Text(
                'Ask Nooto',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: AppStyles.spacingXS),
              Text(
                'On-device parsing. Set an alarm, start a timer, add an event, or make a reminder.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppStyles.spacingL),
              if (availability == null)
                _availabilityChecking()
              else if (!availability.available)
                _availabilityUnavailable(availability.reason)
              else
                _inputAndResult(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _grabber() {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.textTertiary.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _availabilityChecking() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppStyles.spacingL),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandPrimary),
          ),
          SizedBox(width: AppStyles.spacingM),
          Text('Checking Apple Intelligence…',
              style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _availabilityUnavailable(String? reason) {
    return Container(
      padding: const EdgeInsets.all(AppStyles.spacingL),
      decoration: BoxDecoration(
        color: AppColors.backgroundSecondary,
        borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.auto_awesome_outlined, size: 20, color: AppColors.textSecondary),
          const SizedBox(width: AppStyles.spacingM),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Apple Intelligence unavailable',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppStyles.spacingXS),
                Text(
                  reason ?? 'Reason unknown.',
                  style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _inputAndResult() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          enabled: !_isRunning,
          maxLines: 3,
          minLines: 1,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _run(),
          style: const TextStyle(fontSize: 16, color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: 'e.g. lunch at noon, remind me to buy milk',
            hintStyle: const TextStyle(fontSize: 16, color: AppColors.textTertiary),
            filled: true,
            fillColor: AppColors.backgroundSecondary,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppStyles.spacingL,
              vertical: AppStyles.spacingM,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
              borderSide: const BorderSide(color: AppColors.brandPrimary),
            ),
          ),
        ),
        const SizedBox(height: AppStyles.spacingM),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton(
            onPressed: _isRunning ? null : _run,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brandPrimary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
              ),
            ),
            child: _isRunning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Run', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ),
        if (_lastResult != null) ...[
          const SizedBox(height: AppStyles.spacingL),
          _resultPanel(_lastResult!),
        ],
      ],
    );
  }

  Widget _resultPanel(IntentResult result) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppStyles.spacingL),
      decoration: BoxDecoration(
        color: AppColors.backgroundSecondary,
        borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_iconForKind(result.intentKind), size: 16, color: AppColors.textSecondary),
              const SizedBox(width: AppStyles.spacingS),
              Text(
                _headlineForResult(result),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                '${result.latencyMs} ms',
                style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
              ),
            ],
          ),
          const SizedBox(height: AppStyles.spacingM),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              result.parsedJson,
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          if (result.failureReason != null) ...[
            const SizedBox(height: AppStyles.spacingM),
            Text(
              result.failureReason!,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.warningColor,
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _iconForKind(IntentKind kind) {
    return switch (kind) {
      IntentKind.setAlarm => Icons.alarm,
      IntentKind.startTimer => Icons.timer_outlined,
      IntentKind.addEvent => Icons.event_outlined,
      IntentKind.makeReminder => Icons.task_alt_outlined,
      IntentKind.unknown => Icons.help_outline,
    };
  }

  String _headlineForResult(IntentResult result) {
    if (result.blockedBySafetyClassifier) return 'Blocked by safety classifier';
    return switch ((result.intentKind, result.status)) {
      (IntentKind.setAlarm, DispatchStatus.success) => 'Alarm dispatched',
      (IntentKind.startTimer, DispatchStatus.success) => 'Timer dispatched',
      (IntentKind.addEvent, DispatchStatus.success) => 'Event added',
      (IntentKind.makeReminder, DispatchStatus.success) => 'Reminder added',
      (IntentKind.unknown, _) => "Couldn't interpret that",
      (_, DispatchStatus.failed) => '${result.intentKind.displayLabel}: dispatch failed',
      (_, DispatchStatus.noop) => '${result.intentKind.displayLabel}: no action',
    };
  }
}
