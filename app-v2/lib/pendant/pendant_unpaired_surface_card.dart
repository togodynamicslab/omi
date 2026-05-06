import 'package:flutter/material.dart';

import 'package:nooto_v2/theme/app_theme.dart';

/// Shared surface card for every "settled-unpaired" variant on the pendant
/// screen.
///
/// This consolidates the chrome that previously lived duplicated across five
/// near-identical bodies inside `pendant_screen.dart`
/// (`unpaired`, `permissionDenied`, `incompatible`, plus the two
/// ceremony-failure variants `ceremonyTimeout` and `ceremonyBleError`).
///
/// See the design doc — `matheusoliviera-main-design-pendant-magic-moment-`
/// `20260504-124235.md`, finding **CQ-1** (DRY consolidation across the five
/// settled-unpaired variants) — for the rationale: a single primitive owns
/// surface chrome, body text, primary CTA, and the optional secondary CTA so
/// new failure-path surfaces stay one-line additions instead of new copies of
/// the chrome.
///
/// Visual contract (matches `_SurfaceCard` chrome from `pendant_screen.dart`
/// and tokens from `DESIGN.md` "Surface cards"):
/// - `AppColors.backgroundSecondary` fill, `AppStyles.radiusLarge` corners,
///   1px `AppColors.backgroundTertiary` border, `AppStyles.spacingL` padding.
/// - Body text: 14pt, `AppColors.textSecondary`, line-height 1.4.
/// - Primary CTA: filled brand-blue pill, 44pt min height (HIG touch target).
/// - Optional secondary CTA: text button below the primary, same min height.
///
/// String props (no l10n inside this widget — Subagent 6 owns l10n keys; this
/// widget accepts already-resolved strings so the screen can pass them in).
class PendantUnpairedSurfaceCard extends StatelessWidget {
  const PendantUnpairedSurfaceCard({
    super.key,
    required this.message,
    required this.primaryCtaLabel,
    required this.onPrimaryTap,
    this.secondaryCtaLabel,
    this.onSecondaryTap,
  }) : assert(
         secondaryCtaLabel == null || onSecondaryTap != null,
         'onSecondaryTap required when secondaryCtaLabel is provided',
       );

  /// Body text shown above the CTA(s). Required.
  final String message;

  /// Filled brand-blue primary CTA label. Required.
  final String primaryCtaLabel;

  /// Callback when primary CTA is tapped. Required.
  final VoidCallback onPrimaryTap;

  /// Optional secondary CTA label. When non-null, a text button is rendered
  /// below the primary.
  final String? secondaryCtaLabel;

  /// Optional secondary CTA callback. Required when [secondaryCtaLabel] is
  /// provided (enforced by assertion in the constructor).
  final VoidCallback? onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    // Style aligned with the in-constellation failure overlay (per
    // 2026-05-05 dogfood: "the hold your pendant close and pair pendant
    // needs to match our pendant screen style"). No surface-card chrome —
    // the dark scaffold background carries the visual; copy is light
    // weight + secondary color, primary CTA is a brand-blue text-link
    // (NOT a chunky filled pill), secondary CTA dimmer below. This keeps
    // visual continuity with the takeover layout's Try Again / Back
    // buttons so the unpaired → pairing → settled flow reads as one
    // coherent screen aesthetic.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w300,
            color: AppColors.textSecondary,
            letterSpacing: -0.1,
            height: 1.4,
          ),
        ),
        const SizedBox(height: AppStyles.spacingXL),
        Semantics(
          button: true,
          label: primaryCtaLabel,
          child: TextButton(
            onPressed: onPrimaryTap,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.brandPrimary,
              minimumSize: const Size.fromHeight(AppStyles.touchTargetMinimum),
              padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
            ),
            child: Text(
              primaryCtaLabel,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500, letterSpacing: -0.2),
            ),
          ),
        ),
        if (secondaryCtaLabel != null)
          Semantics(
            button: true,
            label: secondaryCtaLabel!,
            child: TextButton(
              onPressed: onSecondaryTap,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textTertiary,
                minimumSize: const Size.fromHeight(AppStyles.touchTargetMinimum),
                padding: const EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
              ),
              child: Text(
                secondaryCtaLabel!,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w400, letterSpacing: -0.1),
              ),
            ),
          ),
      ],
    );
  }
}
