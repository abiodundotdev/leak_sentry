import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/retain_instance_event.dart';
import 'package:leak_sentry/leak_sentry.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/format.dart';
import 'package:leak_sentry/ui/leak_sentry_route.dart';

import 'helpers/capture_log.dart';
import 'helpers/engine_fixture.dart';
import 'helpers/leak_events.dart';
import 'helpers/pump_ui.dart' show captureClipboard;

const _badge = ValueKey('leak_sentry_overlay_badge');
const _notice = ValueKey('leak_sentry_overlay_notice');
const _unread = ValueKey('leak_sentry_overlay_unread');

/// The overlay above the app's navigator, as `MaterialApp.builder` puts it.
Widget _aboveTheNavigator({Widget home = const Scaffold(body: Text('the app'))}) =>
    MaterialApp(builder: (context, child) => LeakSentryOverlay(child: child ?? const SizedBox()), home: home);

/// The overlay inside a page, below the app's navigator, with none of its own below it.
Widget _insideAPage() => const MaterialApp(home: LeakSentryOverlay(child: Scaffold(body: Text('the app'))));

void main() {
  late EngineFixture f;

  setUp(() {
    captureLog();
    f = EngineFixture();
    InternalLeakSentryHolder.use(f);
  });

  tearDown(LeakSentry.resetForTesting);

  /// A leak that is a resource nobody closed: found without a scan.
  void leakResource(String label) {
    f.finalizer.simulateCollected(f.engine.resourceTracker.trackResource(Object(), label: label));
  }

  group('the badge', () {
    testWidgets('is not there while there is nothing to show', (tester) async {
      await tester.pumpWidget(_aboveTheNavigator());

      expect(find.byKey(_badge), findsNothing);
      expect(find.byKey(_notice), findsNothing);
      expect(find.text('the app'), findsOneWidget);
    });

    testWidgets('appears when a leak is found, and counts the distinct leaks', (tester) async {
      await tester.pumpWidget(_aboveTheNavigator());

      leakResource('one');
      await tester.pump();
      expect(find.text('1 leak'), findsOneWidget);

      leakResource('two');
      await tester.pump();
      expect(find.text('2 leaks'), findsOneWidget);
    });

    testWidgets('a leak that is found again is not another leak', (tester) async {
      await tester.pumpWidget(_aboveTheNavigator());

      leakResource('same');
      leakResource('same');
      await tester.pump();

      expect(find.text('1 leak'), findsOneWidget);
    });

    testWidgets('shows the leaks that were found before it was mounted', (tester) async {
      leakResource('early leak');

      await tester.pumpWidget(_aboveTheNavigator());

      expect(find.text('1 leak'), findsOneWidget);
    });

    testWidgets('says there is something new while a leak has not been opened', (tester) async {
      await tester.pumpWidget(_aboveTheNavigator());
      leakResource('one');
      await tester.pump();
      expect(find.byKey(_unread), findsOneWidget);

      f.engine.catalog.markRead(f.engine.catalog.groups.single.id);
      await tester.pump();

      expect(find.byKey(_unread), findsNothing);
      expect(find.byKey(_badge), findsOneWidget);
    });

    testWidgets('is a button, and says how many leaks and what it opens', (tester) async {
      final handle = tester.ensureSemantics();
      leakResource('one');
      leakResource('two');
      await tester.pumpWidget(_aboveTheNavigator());

      expect(
        tester.getSemantics(find.byKey(_badge)),
        matchesSemantics(isButton: true, hasTapAction: true, label: '2 leaks. Open LeakSentry'),
      );
      handle.dispose();
    });

    testWidgets('goes away when the leaks are cleared', (tester) async {
      leakResource('one');
      await tester.pumpWidget(_aboveTheNavigator());

      f.engine.clearLeaks();
      await tester.pump();

      expect(find.byKey(_badge), findsNothing);
    });

    testWidgets('leaves the app below it as it was', (tester) async {
      await tester.pumpWidget(_aboveTheNavigator(home: const Scaffold(body: _Counter())));
      await tester.tap(find.byType(_Counter));
      await tester.pump();
      expect(find.text('taps: 1'), findsOneWidget);

      leakResource('one');
      await tester.pump();

      expect(find.text('taps: 1'), findsOneWidget, reason: 'the app was not rebuilt from scratch');
    });
  });

  group('the notice', () {
    testWidgets('says how many objects are held, and how many it takes to scan', (tester) async {
      await tester.pumpWidget(_aboveTheNavigator());

      f.engine.notices.showRetainedCount(objectCount: 2, contentText: 'x', reason: const BelowThresholdEvent(2));
      await tester.pump();

      expect(find.byKey(_notice), findsOneWidget);
      expect(find.text('2 held · scans at 5'), findsOneWidget);
      expect(find.byKey(_badge), findsNothing, reason: 'no leaks yet, only a notice');
    });

    testWidgets('follows the threshold that is set', (tester) async {
      f.engine.config = f.engine.config.copyWith(retainedVisibleThreshold: 8);
      await tester.pumpWidget(_aboveTheNavigator());

      f.engine.notices.showRetainedCount(objectCount: 3, contentText: 'x', reason: const BelowThresholdEvent(3));
      await tester.pump();

      expect(find.text('3 held · scans at 8'), findsOneWidget);
    });

    testWidgets('says the other things the trigger says', (tester) async {
      await tester.pumpWidget(_aboveTheNavigator());

      f.engine.notices.showRetainedCount(objectCount: 4, contentText: 'x', reason: const DumpHappenedRecentlyEvent());
      await tester.pump();
      expect(find.text('4 held · scanned moments ago'), findsOneWidget);

      f.engine.notices.showRetainedCount(objectCount: 4, contentText: 'x', reason: const DumpingDisabledEvent('x'));
      await tester.pump();
      expect(find.text('4 held · scanning is off'), findsOneWidget);

      f.engine.notices.showRetainedCount(objectCount: 4, contentText: 'Failed to dump heap');
      await tester.pump();
      expect(find.text('4 held · last scan failed'), findsOneWidget);

      f.engine.notices.showNoMoreRetainedObjects();
      await tester.pump();
      expect(find.text('All clear'), findsOneWidget);
    });

    testWidgets('says nothing when a scan was asked for and nothing was held', (tester) async {
      await tester.pumpWidget(_aboveTheNavigator());

      f.engine.notices.showNoRetainedObjectsOnRequest();
      await tester.pump();

      expect(find.byKey(_notice), findsNothing);
    });

    testWidgets('goes when it is dismissed', (tester) async {
      await tester.pumpWidget(_aboveTheNavigator());
      f.engine.notices.showRetainedCount(objectCount: 2, contentText: 'x', reason: const BelowThresholdEvent(2));
      await tester.pump();

      f.engine.notices.dismissRetainedCount();
      await tester.pump();

      expect(find.byKey(_notice), findsNothing);
    });

    testWidgets('sits above the badge when there are leaks too', (tester) async {
      leakResource('one');
      await tester.pumpWidget(_aboveTheNavigator());

      f.engine.notices.showRetainedCount(objectCount: 2, contentText: 'x', reason: const BelowThresholdEvent(2));
      await tester.pump();

      expect(find.byKey(_badge), findsOneWidget);
      expect(find.byKey(_notice), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(_notice)).dy, lessThan(tester.getTopLeft(find.byKey(_badge)).dy));
    });
  });

  group('opening the screen from the badge', () {
    testWidgets('shows the leaks, as a page of the app\'s navigator', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await tester.pumpWidget(_aboveTheNavigator());

      await tester.tap(find.byKey(_badge));
      await tester.pumpAndSettle();

      expect(find.byType(LeakSentryScreen), findsOneWidget);
      expect(find.text(LeakSentryCopy.tabLeaks), findsWidgets);
      expect(find.text('lib/main.dart:196'), findsOneWidget, reason: 'where the object was created, on the list');
      expect(find.text(breakable('_PageThreeState.initState', after: '.')), findsOneWidget);
      expect(find.byType(LeakSentryRoute<void>, skipOffstage: false), findsNothing, reason: 'a route is not a widget');
      expect(tester.takeException(), isNull);
    });

    testWidgets('hides the badge while it is open, and brings it back when it is closed', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await tester.pumpWidget(_aboveTheNavigator());

      await tester.tap(find.byKey(_badge));
      await tester.pumpAndSettle();
      expect(find.byKey(_badge), findsNothing);
      expect(f.engine.screenOpen.value, isTrue);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(LeakSentryScreen), findsNothing);
      expect(find.byKey(_badge), findsOneWidget);
      expect(f.engine.screenOpen.value, isFalse);
    });

    testWidgets('keeps the badge away while a page of the screen is open on top of it', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await tester.pumpWidget(_aboveTheNavigator());
      await tester.tap(find.byKey(_badge));
      await tester.pumpAndSettle();

      await tester.tap(find.text('PageThreeState'));
      await tester.pumpAndSettle();
      expect(find.byKey(_badge), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(_badge), findsNothing, reason: 'the screen is still open under it');

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(_badge), findsOneWidget);
    });

    testWidgets('tapping the notice opens the scans', (tester) async {
      await tester.pumpWidget(_aboveTheNavigator());
      f.engine.notices.showRetainedCount(objectCount: 2, contentText: 'x', reason: const BelowThresholdEvent(2));
      await tester.pump();

      await tester.tap(find.byKey(_notice));
      await tester.pumpAndSettle();

      expect(find.descendant(of: find.byType(AppBar), matching: find.text(LeakSentryCopy.tabScans)), findsOneWidget);
      expect(find.text('2 objects held'), findsOneWidget);
    });

    testWidgets('opens one screen however many times it is asked', (tester) async {
      leakResource('one');
      await tester.pumpWidget(_aboveTheNavigator());

      unawaitedShow();
      unawaitedShow();
      await tester.tap(find.byKey(_badge), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.byType(LeakSentryScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(LeakSentryScreen), findsNothing, reason: 'one back press closes it');
    });

    testWidgets('works in the screen it opens: a dialog needs an overlay, which it has', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await tester.pumpWidget(_aboveTheNavigator());
      await tester.tap(find.byKey(_badge));
      await tester.pumpAndSettle();

      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(LeakSentryCopy.tabSettings)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(LeakSentryCopy.settingsClear));
      await tester.pump();
      await tester.tap(find.text(LeakSentryCopy.settingsClear));
      await tester.pumpAndSettle();

      expect(find.text(LeakSentryCopy.settingsClearConfirmTitle), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('without a navigator below it', () {
    testWidgets('shows the screen over the app, in a navigator of its own', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await tester.pumpWidget(_insideAPage());

      await tester.tap(find.byKey(_badge));
      await tester.pumpAndSettle();

      expect(find.byType(LeakSentryScreen), findsOneWidget);
      expect(find.text('lib/main.dart:196'), findsOneWidget);
      expect(find.text(breakable('_PageThreeState.initState', after: '.')), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget, reason: 'it has no back button to close it with');
      expect(tester.takeException(), isNull);
    });

    testWidgets('is closed by its close button, and the badge comes back', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await tester.pumpWidget(_insideAPage());
      await tester.tap(find.byKey(_badge));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.byType(LeakSentryScreen), findsNothing);
      expect(find.byKey(_badge), findsOneWidget);
      expect(f.engine.screenOpen.value, isFalse);
    });

    testWidgets('a leak can be opened in it, and closed with the back button of its page', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await tester.pumpWidget(_insideAPage());
      await tester.tap(find.byKey(_badge));
      await tester.pumpAndSettle();

      await tester.tap(find.text('PageThreeState'));
      await tester.pumpAndSettle();
      expect(find.text(LeakSentryCopy.whereCreated), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(LeakSentryScreen), findsOneWidget);
      expect(find.text(LeakSentryCopy.whereCreated), findsNothing);
    });
  });

  group('LeakSentry.showScreen', () {
    testWidgets('shows the screen on the navigator of a context', (tester) async {
      late BuildContext inApp;
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => inApp = context, child: const Text('go'))))),
      );
      await tester.tap(find.text('go'));

      LeakSentry.showScreen(inApp);
      await tester.pumpAndSettle();

      expect(find.byType(LeakSentryScreen), findsOneWidget);
    });

    testWidgets('opens on the tab it is asked to', (tester) async {
      late BuildContext inApp;
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => inApp = context, child: const Text('go'))))),
      );
      await tester.tap(find.text('go'));

      LeakSentry.showScreen(inApp, LeakSentryTab.settings);
      await tester.pumpAndSettle();

      expect(find.text(LeakSentryCopy.settingsScanAutomatically), findsOneWidget);
    });

    testWidgets('without a context uses the navigator under the badge\'s overlay', (tester) async {
      await tester.pumpWidget(_aboveTheNavigator());

      LeakSentry.showScreen();
      await tester.pumpAndSettle();

      expect(find.byType(LeakSentryScreen), findsOneWidget);
    });

    testWidgets('with a context above the app\'s navigator opens through the overlay instead of throwing', (tester) async {
      late BuildContext aboveTheNavigator;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) {
            aboveTheNavigator = context;
            return LeakSentryOverlay(child: child ?? const SizedBox());
          },
          home: const Scaffold(body: Text('the app')),
        ),
      );

      LeakSentry.showScreen(aboveTheNavigator);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(LeakSentryScreen), findsOneWidget);
    });

    testWidgets('with a context above the app\'s navigator and no overlay says what is needed, and does nothing', (tester) async {
      final log = captureLog();
      late BuildContext aboveTheNavigator;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) {
            aboveTheNavigator = context;
            return child ?? const SizedBox();
          },
          home: const Scaffold(),
        ),
      );

      await LeakSentry.showScreen(aboveTheNavigator);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(LeakSentryScreen), findsNothing);
      expect(log.lines.single, contains('needs a context below a Navigator'));
    });

    testWidgets('without a context and without an overlay says what is needed, and does nothing', (tester) async {
      final log = captureLog();
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));

      await LeakSentry.showScreen();
      await tester.pump();

      expect(find.byType(LeakSentryScreen), findsNothing);
      expect(log.lines.single, contains('LeakSentryOverlay'));
    });

    testWidgets('does not open a second screen on top of the first', (tester) async {
      late BuildContext inApp;
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => inApp = context, child: const Text('go'))))),
      );
      await tester.tap(find.text('go'));

      LeakSentry.showScreen(inApp);
      LeakSentry.showScreen(inApp);
      await tester.pumpAndSettle();

      expect(find.byType(LeakSentryScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(LeakSentryScreen), findsNothing);
    });
  });

  group('in a release build', () {
    testWidgets('shows no badge when LeakSentry was not installed: a resource leak is not for the people using the app', (tester) async {
      final release = EngineFixture(release: true);
      InternalLeakSentryHolder.use(release);
      addTearDown(release.engine.dispose);
      await tester.pumpWidget(_aboveTheNavigator());

      release.finalizer.simulateCollected(release.engine.resourceTracker.trackResource(Object(), label: 'a resource'));
      await tester.pump();

      expect(release.engine.catalog.leakCount, 1, reason: 'it is found');
      expect(find.byKey(_badge), findsNothing);
      expect(find.text('the app'), findsOneWidget);
    });

    testWidgets('shows it when the app installed LeakSentry on purpose', (tester) async {
      final release = EngineFixture(release: true);
      InternalLeakSentryHolder.use(release);
      addTearDown(release.engine.dispose);
      release.engine.install(watchers: const [], allowInRelease: true);
      await tester.pumpWidget(_aboveTheNavigator());

      release.finalizer.simulateCollected(release.engine.resourceTracker.trackResource(Object(), label: 'a resource'));
      await tester.pump();

      expect(find.byKey(_badge), findsOneWidget);
    });
  });

  group('the navigator the overlay opens the screen on', () {
    testWidgets('is found when it is needed, and not kept: the app that has it may be replaced', (tester) async {
      await tester.pumpWidget(_aboveTheNavigator(home: const Scaffold(body: Text('first app'))));
      LeakSentry.showScreen();
      await tester.pumpAndSettle();
      expect(find.byType(LeakSentryScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      // The same overlay, over another app: a navigator of another key.
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          builder: (context, child) => LeakSentryOverlay(child: child ?? const SizedBox()),
          home: const Scaffold(body: Text('second app')),
        ),
      );
      LeakSentry.showScreen();
      await tester.pumpAndSettle();

      expect(find.byType(LeakSentryScreen), findsOneWidget);
      expect(find.text('second app'), findsNothing, reason: 'the screen is over the second app, not the first');
    });
  });

  group('the opener the overlay registers', () {
    testWidgets('is there while the overlay is on the screen, and gone after', (tester) async {
      expect(f.engine.screenOpener, isNull);

      await tester.pumpWidget(_aboveTheNavigator());
      expect(f.engine.screenOpener, isNotNull);

      await tester.pumpWidget(const SizedBox());
      expect(f.engine.screenOpener, isNull);
    });

    testWidgets('is not taken away by one overlay going when another has taken it over', (tester) async {
      // Two overlays at once: the second to mount is the one the engine opens screens with.
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Expanded(key: ValueKey('first'), child: LeakSentryOverlay(child: SizedBox())),
              Expanded(key: ValueKey('second'), child: LeakSentryOverlay(child: SizedBox())),
            ],
          ),
        ),
      );
      final opener = f.engine.screenOpener;
      expect(opener, isNotNull);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [Expanded(key: ValueKey('second'), child: LeakSentryOverlay(child: SizedBox()))],
          ),
        ),
      );

      expect(f.engine.screenOpener, isNotNull, reason: 'the first overlay going must not take the second one\'s opener');
      expect(f.engine.screenOpener, opener);
    });
  });

  group('in an app that is not a Material app', () {
    testWidgets('the badge and the screen work, and dialogs do too', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await tester.pumpWidget(
        WidgetsApp(
          color: const Color(0xFF000000),
          builder: (context, child) => LeakSentryOverlay(child: child ?? const SizedBox()),
          pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(settings: settings, pageBuilder: (context, _, __) => builder(context)),
          home: const Center(child: Text('a widgets app')),
        ),
      );

      await tester.tap(find.byKey(_badge));
      await tester.pumpAndSettle();
      expect(find.byType(LeakSentryScreen), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(LeakSentryCopy.tabSettings)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(LeakSentryCopy.settingsClear));
      await tester.pump();
      await tester.tap(find.text(LeakSentryCopy.settingsClear));
      await tester.pumpAndSettle();

      expect(find.text(LeakSentryCopy.settingsClearConfirmTitle), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('and so do the messages: copying a report says so, though the app has no messenger', (tester) async {
      captureClipboard(tester);
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await tester.pumpWidget(
        WidgetsApp(
          color: const Color(0xFF000000),
          builder: (context, child) => LeakSentryOverlay(child: child ?? const SizedBox()),
          pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(settings: settings, pageBuilder: (context, _, __) => builder(context)),
          home: const Center(child: Text('a widgets app')),
        ),
      );
      await tester.tap(find.byKey(_badge));
      await tester.pumpAndSettle();
      await tester.tap(find.text('PageThreeState'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(LeakSentryCopy.copyReport));
      await tester.pump();

      expect(find.text(LeakSentryCopy.reportCopied), findsOneWidget);
    });
  });

  group('whatever the screen', () {
    for (final (scale, width) in const [(1.0, 400.0), (1.5, 400.0), (1.0, 320.0), (1.5, 320.0)]) {
      testWidgets('the badge and the notice fit at text scale $scale, $width wide', (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        for (var i = 0; i < 12; i++) {
          leakResource('leak $i');
        }
        f.engine.notices.showRetainedCount(objectCount: 12, contentText: 'x', reason: const BelowThresholdEvent(12));

        await tester.pumpWidget(_aboveTheNavigator());

        expect(tester.takeException(), isNull);
        expect(find.text('12 leaks'), findsOneWidget);
      });
    }
  });
}

/// Asks for the screen the way the app would, without waiting for it.
void unawaitedShow() {
  LeakSentry.showScreen();
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;

  @override
  Widget build(BuildContext context) =>
      GestureDetector(onTap: () => setState(() => taps++), child: Text('taps: $taps'));
}
