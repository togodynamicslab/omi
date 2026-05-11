//! Feature flags for controlled rollout of new surfaces.
//!
//! Each flag has a matching TypeScript const in
//! `src/config/companionFeatureFlag.ts`. Both must be flipped together when
//! toggling a cutover for a release.

/// When `true`:
/// - The `Cmd+Ctrl+\` global shortcut toggles the Companion buddy instead of
///   the legacy Ask Nooto floating bar.
/// - The `floating` and `whispr` windows are closed at startup so they never
///   appear in the UI.
///
/// Currently `false`: the Settings entry "Toggle shortcut" advertises a
/// floating composer (text-to-Nooto), so the shortcut needs to actually open
/// that bar. Flip back to `true` once the Companion buddy is the intended
/// destination for `Cmd+Ctrl+\` and the Settings copy is updated.
pub const COMPANION_CUTOVER_ENABLED: bool = false;

/// When `true`, the Coding Agent surface (Pi sidecar + chat UI) is shown in the
/// sidebar and routable. When `false`, the route is unmounted and the nav entry
/// is hidden — the underlying code still ships, just dark.
///
/// Default: `false` until the feature has soaked in internal dogfood.
pub const CODING_AGENT_ENABLED: bool = true;
