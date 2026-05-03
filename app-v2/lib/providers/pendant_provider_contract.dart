import 'package:flutter/foundation.dart';

import 'package:nooto_v2/services/ble/pendant_state.dart';

/// Forward-declared contract for `PendantProvider`, the `ChangeNotifier` that
/// Lane C (service stack) lands at the app root.
///
/// Lane D (UI) depends on this surface only — never on the concrete service
/// implementation — so widget code and widget tests can consume the same
/// type whether the runtime instance is the real provider (Lane C) or a
/// fake (test helpers).
///
/// Concrete implementation arrives in `pendant_provider.dart` once Lane C
/// merges. Until then, this abstract class is the public seam:
///
///   - `info` — current `PendantInfo` snapshot the UI renders against.
///   - `startPair()` — user-initiated pairing kickoff (sheet "Pair" / "Try
///     again" buttons call this).
///   - `reconnect()` — user-initiated reconnect attempt (offline-pill tap and
///     offline voice card tap call this).
///
/// `extends ChangeNotifier` so callers can use `Provider.of<PendantProvider>`
/// or `context.watch<PendantProvider>()` for rebuilds on state change.
abstract class PendantProvider extends ChangeNotifier {
  /// Latest snapshot of the pendant's connection state. Drives every UI
  /// surface in the State × surface matrix (status pill, pairing sheet,
  /// connect-pendant voice card, onboarding turn).
  PendantInfo get info;

  /// Begin a pairing flow. Idempotent — safe to call from "Pair" buttons in
  /// the pairing sheet, "Try again" CTAs after `incompatible`, or the
  /// onboarding turn.
  Future<void> startPair();

  /// Re-attempt connection without re-pairing. Called from the offline pill
  /// tap and the offline voice card tap.
  Future<void> reconnect();
}
