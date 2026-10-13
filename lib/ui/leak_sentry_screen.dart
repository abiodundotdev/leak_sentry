import 'package:flutter/material.dart';
import 'package:meta/meta.dart' show internal;
import 'package:leak_sentry/core/internal_leak_sentry.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/core/leak_sentry_log.dart';
import 'package:leak_sentry/core/leak_sentry_tab.dart';
import 'package:leak_sentry/models/leak_sentry_internal.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/leak_sentry_route.dart';
import 'package:leak_sentry/ui/screens/leak_detail_page.dart';
import 'package:leak_sentry/ui/screens/leaks_tab.dart';
import 'package:leak_sentry/ui/screens/scan_detail_page.dart';
import 'package:leak_sentry/ui/screens/scans_tab.dart';
import 'package:leak_sentry/ui/screens/settings_tab.dart';
import 'package:leak_sentry/ui/skin.dart';
import 'package:leak_sentry/ui/widgets/floating_navigation_bar.dart';

/// The LeakSentry screen: the leaks found so far, the scans that found them, and
/// the switches. Open it from the badge, with `LeakSentry.showScreen`, or put it
/// in a debug menu of your own.
class LeakSentryScreen extends StatefulWidget {
  const LeakSentryScreen({super.key, this.initialTab = LeakSentryTab.leaks, this.onClose}) : engine = null;

  /// The same, for the engine given: what the badge and the tests use.
  @internal
  const LeakSentryScreen.withEngine({
    super.key,
    required InternalLeakSentry this.engine,
    this.initialTab = LeakSentryTab.leaks,
    this.onClose,
  });

  /// The tab it opens on.
  final LeakSentryTab initialTab;

  /// Called when the close button is tapped. Without it the screen is closed like
  /// any page, with the back button, which is how it is shown in a navigator.
  final VoidCallback? onClose;

  /// The engine whose leaks it shows. The one `LeakSentry` uses, unless it is given.
  final InternalLeakSentry? engine;

  @override
  State<LeakSentryScreen> createState() => _LeakSentryScreenState();
}

class _LeakSentryScreenState extends State<LeakSentryScreen> implements LeakSentryInternal {
  late LeakSentryTab _tab = widget.initialTab;

  InternalLeakSentry get _engine => widget.engine ?? InternalLeakSentry.instance;

  @override
  Widget build(BuildContext context) {
    return LeakSentrySkin(
      child: Scaffold(
        extendBody: true,
        appBar: AppBar(
          automaticallyImplyLeading: widget.onClose == null,
          leading: widget.onClose == null
              ? null
              : IconButton(icon: const Icon(Icons.close), onPressed: widget.onClose),
          title: Text(switch (_tab) {
            LeakSentryTab.leaks => LeakSentryCopy.tabLeaks,
            LeakSentryTab.scans => LeakSentryCopy.tabScans,
            LeakSentryTab.settings => LeakSentryCopy.tabSettings,
          }),
        ),
        body: IndexedStack(
          index: _tab.index,
          children: [
            LeaksTab(engine: _engine, onOpenLeak: _openLeak),
            ScansTab(engine: _engine, onOpenScan: _openScan),
            SettingsTab(engine: _engine),
          ],
        ),
        bottomNavigationBar: ListenableBuilder(
          listenable: _engine.catalog,
          builder: (context, _) => LeakSentryNavigationBar(
            selectedIndex: _tab.index,
            unreadLeaks: _engine.catalog.unreadCount,
            onSelected: (index) => setState(() => _tab = LeakSentryTab.values[index]),
          ),
        ),
      ),
    );
  }

  void _openLeak(LeakGroup group) => _pushLeak(group.id);

  void _pushLeak(String groupId) {
    Navigator.of(context).push(
      LeakSentryRoute<void>(engine: _engine, builder: (_) => LeakDetailPage(engine: _engine, groupId: groupId)),
    );
  }

  void _openScan(ScanRecord scan) {
    Navigator.of(context).push(
      LeakSentryRoute<void>(
        engine: _engine,
        builder: (_) => ScanDetailPage(engine: _engine, scanId: scan.id, onOpenLeak: _pushLeak),
      ),
    );
  }
}

/// Shows the LeakSentry screen as a route of the navigator [context] is in.
/// Does nothing if one is already showing.
Future<void> showLeakSentryScreen(
  BuildContext context, {
  LeakSentryTab tab = LeakSentryTab.leaks,
  InternalLeakSentry? engine,
}) {
  final used = engine ?? InternalLeakSentry.instance;
  if (used.isScreenOpen) return Future<void>.value();
  final navigator = Navigator.maybeOf(context, rootNavigator: true);
  if (navigator == null) {
    // A context above the app's navigator, such as one in `MaterialApp.builder`: the overlay knows
    // where the navigator is.
    final opener = used.screenOpener;
    if (opener != null) return opener(tab);
    LeakSentryLog.d(
      () => 'LeakSentry.showScreen needs a context below a Navigator, or a LeakSentryOverlay in the widget tree.',
    );
    return Future<void>.value();
  }
  return navigator.push(
    LeakSentryRoute<void>(
      engine: used,
      settings: const RouteSettings(name: '/leak_sentry'),
      builder: (_) => LeakSentryScreen.withEngine(engine: used, initialTab: tab),
    ),
  );
}
