/// Build-time flags. v2 reuses the legacy `nooto-dev` Firebase project and
/// dev bundle IDs (`com.nooto-app-with-wearable.ios12.development` /
/// `com.togodynamics.nooto.dev`) — see `lib/firebase_options.dart`. Real
/// Firebase auth is on for v2 dev builds.
const bool kEnableFirebaseAuth = true;

/// Hooks that fire a Jira sync when the app gains user attention (foreground
/// resume, Plan tab focus). Keeps Plan/brief data fresh without forcing the
/// user to tap "Sync now". Disable to revert to cron-only behavior (10-min
/// Modal cron remains active in either case as a safety net).
const bool kEnableAttentionDrivenJiraRefresh = true;
