import 'package:flutter_test/flutter_test.dart';

import 'package:nooto_v2/home/home_nav.dart';

void main() {
  group('HomeNav.switchToTab', () {
    test('forwards tabIndex to the underlying callback', () {
      int? captured;
      final nav = HomeNav(switchToTab: (idx) => captured = idx);

      nav.switchToTab(2);

      expect(captured, 2);
    });

    test('switchToTab with focusItemId stashes for later consumption', () {
      final nav = HomeNav(switchToTab: (_) {});

      nav.switchToTab(HomeNav.planTabIndex, focusItemId: 'plan-42');

      expect(nav.consumePendingFocusId(), 'plan-42');
    });

    test('switchToTab without focusItemId clears any previously stashed id', () {
      final nav = HomeNav(switchToTab: (_) {});

      nav.switchToTab(HomeNav.planTabIndex, focusItemId: 'plan-42');
      // A subsequent switchToTab with no focusItemId must NOT leave the
      // previous id pending — that would re-trigger the highlight on the
      // next tab activation.
      nav.switchToTab(HomeNav.planTabIndex);

      expect(nav.consumePendingFocusId(), isNull);
    });

    test('consumePendingFocusId is clear-on-read', () {
      final nav = HomeNav(switchToTab: (_) {});
      nav.switchToTab(HomeNav.planTabIndex, focusItemId: 'plan-42');

      expect(nav.consumePendingFocusId(), 'plan-42');
      expect(nav.consumePendingFocusId(), isNull);
      expect(nav.consumePendingFocusId(), isNull);
    });

    test('planTabIndex is 3 (Home=0, Chat=1, Library=2, Plan=3, Apps=4)', () {
      expect(HomeNav.planTabIndex, 3);
    });
  });
}
