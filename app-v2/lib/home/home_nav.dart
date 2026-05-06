/// Lightweight navigation handle exposed to Home stream cards via Provider.
/// Cards call `switchToTab(...)` instead of holding a callback field, which
/// keeps them serializable to Hive without losing nav capability.
///
/// `focusItemId` is consumed-once by the receiving tab. The Plan tab reads
/// `consumePendingFocusId()` on activation, scrolls the matching item into
/// view, and applies a 1500ms `brandPrimary` highlight pulse. The id is
/// cleared on read so a subsequent tab switch without a focus target does
/// not re-trigger the highlight.
class HomeNav {
  HomeNav({required void Function(int tabIndex) switchToTab}) : _switchToTab = switchToTab;

  /// Index of the Plan tab in `ShellScreen` — pinned here so cards don't
  /// hardcode a magic number. Tab 0 = Home, 1 = Chat, 2 = Library, 3 = Plan,
  /// 4 = Apps. Verify against `home_screen.dart` if shell changes.
  static const int planTabIndex = 3;

  final void Function(int tabIndex) _switchToTab;
  String? _pendingFocusItemId;

  /// Switches to [tabIndex]. When [focusItemId] is non-null, it's stashed
  /// for the receiving tab to consume via [consumePendingFocusId].
  void switchToTab(int tabIndex, {String? focusItemId}) {
    _pendingFocusItemId = focusItemId;
    _switchToTab(tabIndex);
  }

  /// Reads and clears the pending focus id. The Plan tab (or any consumer)
  /// calls this on activation to determine whether a chip-tap navigated here
  /// with a target. Returns null if no focus is pending.
  String? consumePendingFocusId() {
    final id = _pendingFocusItemId;
    _pendingFocusItemId = null;
    return id;
  }
}
