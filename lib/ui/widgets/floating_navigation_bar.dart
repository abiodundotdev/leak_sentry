import 'package:flutter/material.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/tokens.dart';

/// The tabs of the screen, in a rounded bar that floats above the content,
/// inset from the edges of the screen.
class LeakSentryNavigationBar extends StatelessWidget {
  const LeakSentryNavigationBar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    this.unreadLeaks = 0,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// How many leaks haven't been opened: shown on the Leaks tab.
  final int unreadLeaks;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    const radius = BorderRadius.all(Radius.circular(LeakSentryMetrics.navigationRadius));
    return Padding(
      padding: EdgeInsets.fromLTRB(
        LeakSentryMetrics.navigationInset,
        0,
        LeakSentryMetrics.navigationInset,
        LeakSentryMetrics.navigationInset + bottom,
      ),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: LeakSentryMetrics.maxContentWidth),
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: LeakSentryColors.surface,
              borderRadius: radius,
              border: Border.fromBorderSide(BorderSide(color: LeakSentryColors.outline)),
              boxShadow: [BoxShadow(color: Color(0x66000000), blurRadius: 20, offset: Offset(0, 8))],
            ),
            child: ClipRRect(
              borderRadius: radius,
              // The bar must not add the safe area a second time.
              child: MediaQuery.removePadding(
                context: context,
                removeBottom: true,
                child: NavigationBar(
                  height: 64,
                  selectedIndex: selectedIndex,
                  onDestinationSelected: onSelected,
                  labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                  destinations: [
                    NavigationDestination(
                      icon: _tabIcon(Icons.water_drop_outlined, unreadLeaks),
                      selectedIcon: _tabIcon(Icons.water_drop, unreadLeaks),
                      label: LeakSentryCopy.tabLeaks,
                    ),
                    const NavigationDestination(
                      icon: Icon(Icons.radar),
                      selectedIcon: Icon(Icons.radar),
                      label: LeakSentryCopy.tabScans,
                    ),
                    const NavigationDestination(
                      icon: Icon(Icons.tune),
                      selectedIcon: Icon(Icons.tune),
                      label: LeakSentryCopy.tabSettings,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The icon of a tab, with how many are unread on it: a mint disc ringed in the colour of the
  /// bar, so that it does not run into the mint of the selected icon.
  Widget _tabIcon(IconData icon, int unread) => Badge(
    isLabelVisible: unread > 0,
    backgroundColor: Colors.transparent,
    padding: EdgeInsets.zero,
    label: DecoratedBox(
      decoration: BoxDecoration(
        color: LeakSentryColors.accent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: LeakSentryColors.surface, width: 2),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
        child: Center(
          widthFactor: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Text(
              '$unread',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: LeakSentryColors.onAccent, height: 1.1),
            ),
          ),
        ),
      ),
    ),
    child: Icon(icon),
  );
}
