/// Outcome of running an [ActionItem] through the proactive-push gate.
///
/// Per Decision 7A in the eng-review, only `pushed` and `userDeleted`
/// outcomes are persisted to the Hive log — every other decision is
/// recomputable from the current ActionItem + prefs state. The enum still
/// names them all because the in-memory diff loop logs each gate result via
/// debugPrint so you can grep `[ProactivePush]` to see why an item was
/// skipped.
///
/// `ok` is the only decision that fires an actual push. Everything else is a
/// reason to skip.
enum GateDecision {
  /// All gates passed — the item is eligible for push.
  ok('ok'),

  /// Backend hasn't shipped confidence for this item yet (older row). We
  /// don't push items we can't score — protects the user from auto-pushing
  /// every legacy item the moment the feature lights up.
  noConfidence('no_confidence'),

  /// Confidence < user-configured threshold.
  belowThreshold('below_threshold'),

  /// Item came from a connected integration. Integration items are owned by
  /// the source tool (Jira / Linear / …) and pushing them to iOS Reminders
  /// would duplicate the user's existing source-of-truth.
  externalSource('external_source'),

  /// User muted this item's external source (or its conversation) in
  /// Settings → Native Sync.
  sourceMuted('source_muted'),

  /// We've already pushed this item before. The log has a `pushed` row.
  alreadyPushed('already_pushed'),

  /// User deleted the iOS reminder for this item earlier. Terminal — we
  /// never push it again, even if the action item's confidence shifts.
  userPreviouslyDeleted('user_previously_deleted'),

  /// We've already pushed `dailyBudget` items today. Cools off until midnight
  /// local time. The item stays in the in-app list and a retry fires on the
  /// next foreground per Decision 14A.
  dailyBudgetExceeded('daily_budget_exceeded'),

  /// iOS Reminders permission denied (or we're not on iOS). The feature
  /// holds — Settings shows a "Permission needed" cue.
  remindersUnavailable('reminders_unavailable'),

  /// Item's `createdAt` is older than `firstSeenAt`. Protects the user from
  /// back-filling existing open items into Reminders on the first run.
  predatesActivation('predates_activation'),

  /// Master toggle is OFF. Should usually be caught upstream of the gate
  /// (the listener doesn't fire), but the gate carries it as a defense in
  /// depth in case something else races.
  featureDisabled('feature_disabled'),

  /// Dispatcher returned a non-success status. We do NOT record this in the
  /// log — see Decision 14A. The item stays unseen so the next foreground
  /// retries it automatically.
  pushFailed('push_failed');

  const GateDecision(this.wire);

  /// Stable string for debug logging — matches the gstack timeline entries.
  final String wire;
}
