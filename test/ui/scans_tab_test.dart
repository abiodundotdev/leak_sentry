import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/heap_analysis.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';
import 'package:leak_sentry/core/leak_sentry_tab.dart';
import 'package:leak_sentry/core/retain_instance_event.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/format.dart';

import '../helpers/capture_log.dart';
import '../helpers/engine_fixture.dart';
import '../helpers/leak_events.dart';
import '../helpers/leak_fixtures.dart';
import '../helpers/pump_ui.dart';

/// `FilledButton.icon` builds a subclass of `FilledButton` on some Flutter versions, which
/// `find.byType` does not match.
Finder get _scanNow => find.ancestor(
  of: find.text(LeakSentryCopy.scanNow),
  matching: find.byWidgetPredicate((widget) => widget is FilledButton),
);

bool _enabled(WidgetTester tester) => tester.widget<FilledButton>(_scanNow).onPressed != null;

class _Thing {}

void main() {
  late EngineFixture f;

  setUp(() {
    captureLog();
    f = EngineFixture();
  });

  tearDown(() => f.engine.dispose());

  Future<void> pumpScans(WidgetTester tester, {double textScale = 1.0, double width = 400}) =>
      pumpScreen(tester, f, tab: LeakSentryTab.scans, textScale: textScale, width: width);

  group('with no scans', () {
    testWidgets('says so, and offers to scan', (tester) async {
      f.engine.install(watchers: const []);

      await pumpScans(tester);

      expect(find.text(LeakSentryCopy.scansEmptyTitle), findsOneWidget);
      expect(find.text(LeakSentryCopy.scanStatusIdle), findsOneWidget);
      expect(find.text(LeakSentryCopy.scanStatusIdleBody), findsOneWidget);
      expect(_enabled(tester), isTrue);
    });

    testWidgets('cannot scan when LeakSentry is not installed, and says why', (tester) async {
      await pumpScans(tester);

      expect(find.text(LeakSentryCopy.blockSentence(blockOf(f))), findsOneWidget);
      expect(_enabled(tester), isFalse);
    });
  });

  group('the scans so far', () {
    testWidgets('are listed, the latest first, each with what it found', (tester) async {
      f.engine.install(watchers: const []);
      runScan(f.engine.catalog, 'a', [leakReport(signature: 'one'), leakReport(type: PageFourState, signature: 'two')], held: 5);
      f.time.advance(const Duration(minutes: 4));
      runScan(f.engine.catalog, 'b', [leakReport(signature: 'one')], held: 2);
      runScan(f.engine.catalog, 'c', [], held: 1);

      await pumpScans(tester);

      expect(find.text('5 held · 2 leaks (2 new)'), findsOneWidget);
      expect(find.text('2 held · 1 leak'), findsOneWidget);
      expect(find.text('1 held · no leaks'), findsOneWidget);
      expect(tester.getTopLeft(find.text('1 held · no leaks')).dy, lessThan(tester.getTopLeft(find.text('5 held · 2 leaks (2 new)')).dy));
      expect(find.text('4 min ago'), findsOneWidget);
    });

    testWidgets('a row has an icon that says how it went', (tester) async {
      f.engine.install(watchers: const []);
      runScan(f.engine.catalog, 'a', [leakReport()]);
      runScan(f.engine.catalog, 'b', []);
      f.engine.catalog.onEvent(HeapDumpFailedEvent('x', exception: StateError('no space'), willRetryLater: true));

      await pumpScans(tester);

      Finder inTheList(IconData icon) => find.descendant(of: find.byType(ListView), matching: find.byIcon(icon));
      expect(inTheList(Icons.water_drop_outlined), findsOneWidget, reason: 'the scan that found a leak');
      expect(inTheList(Icons.check_circle_outline), findsOneWidget, reason: 'the scan that found nothing');
      expect(inTheList(Icons.error_outline), findsOneWidget, reason: 'the dump that failed');
    });

    testWidgets('a failed dump is a row of its own, and says it will be tried again', (tester) async {
      f.engine.install(watchers: const []);
      f.engine.catalog.onEvent(HeapDumpFailedEvent('a', exception: StateError('no space'), willRetryLater: true));
      f.engine.catalog.onEvent(HeapDumpFailedEvent('a', exception: StateError('no space'), willRetryLater: false));

      await pumpScans(tester);

      expect(find.text(LeakSentryCopy.scanFailedWillRetry), findsOneWidget);
      expect(find.text(LeakSentryCopy.scanFailed), findsOneWidget);
    });

    testWidgets('a scan under way says which step it is on, with a progress bar, and cannot be started again', (tester) async {
      f.engine.install(watchers: const []);
      startScan(f.engine.catalog, 'a');
      f.engine.catalog.onEvent(const HeapAnalysisProgressEvent('a', step: AnalysisStep.findingPathsToRetainedObjects, progressPercent: 0.3));

      await pumpScans(tester);

      expect(find.text(LeakSentryCopy.scanRunning), findsNWidgets(2), reason: 'the status card, and the row of the scan');
      expect(find.text('Tracing what holds it'), findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.3);
      expect(_enabled(tester), isFalse);
    });

    testWidgets('the progress moves on as the analysis does, and ends with the scan', (tester) async {
      f.engine.install(watchers: const []);
      startScan(f.engine.catalog, 'a');
      await pumpScans(tester);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      f.engine.catalog.onEvent(const HeapAnalysisProgressEvent('a', step: AnalysisStep.buildingLeakTraces, progressPercent: 0.8));
      await tester.pump();
      expect(find.text('Building the report'), findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.8);

      runScan(f.engine.catalog, 'b', [], held: 1);
      f.engine.catalog.clear();
      runScan(f.engine.catalog, 'c', [], held: 1);
      await tester.pump();

      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(_enabled(tester), isTrue);
    });

    testWidgets('while the heap is being dumped there is nothing to measure yet', (tester) async {
      f.engine.install(watchers: const []);
      f.engine.catalog.onEvent(const DumpingHeapEvent('a'));

      await pumpScans(tester);

      expect(find.text(LeakSentryCopy.scanRunning), findsOneWidget);
      expect(find.text(LeakSentryCopy.scanStatusCapturing), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(_enabled(tester), isFalse);
    });
  });

  group('what is being held', () {
    setUp(() => f.engine.install(watchers: const []));

    testWidgets('while fewer are held than it takes to scan, it says how many it takes', (tester) async {
      f.engine.notices.showRetainedCount(objectCount: 2, contentText: 'x', reason: const BelowThresholdEvent(2));

      await pumpScans(tester);

      expect(find.text('2 objects held'), findsOneWidget);
      expect(find.text(LeakSentryCopy.scanStatusWaiting(5)), findsOneWidget);
    });

    testWidgets('and it follows the threshold that is set', (tester) async {
      f.engine.config = f.engine.config.copyWith(retainedVisibleThreshold: 9);
      f.engine.notices.showRetainedCount(objectCount: 1, contentText: 'x', reason: const BelowThresholdEvent(1));

      await pumpScans(tester);

      expect(find.text('1 object held'), findsOneWidget);
      expect(find.text(LeakSentryCopy.scanStatusWaiting(9)), findsOneWidget);
    });

    testWidgets('right after a scan, it says the next one waits', (tester) async {
      f.engine.notices.showRetainedCount(objectCount: 5, contentText: 'x', reason: const DumpHappenedRecentlyEvent());

      await pumpScans(tester);

      expect(find.text(LeakSentryCopy.scanStatusRecent), findsOneWidget);
    });

    testWidgets('after a scan that failed, it says it will try again', (tester) async {
      f.engine.notices.showRetainedCount(objectCount: 5, contentText: 'Failed to dump heap');

      await pumpScans(tester);

      expect(find.text(LeakSentryCopy.scanStatusFailed), findsOneWidget);
    });

    testWidgets('when scanning is switched off, it says that, and that scanning by hand still works', (tester) async {
      f.engine.dumpEnabledInAboutScreen = false;
      f.engine.notices.showRetainedCount(objectCount: 5, contentText: 'x', reason: const DumpingDisabledEvent('x'));

      await pumpScans(tester);

      expect(find.text(LeakSentryCopy.blockSentence(blockOf(f))), findsOneWidget);
      expect(find.textContaining('Scan now still scans by hand'), findsOneWidget);
      expect(_enabled(tester), isTrue);
    });

    testWidgets('says all clear when everything held was collected', (tester) async {
      f.engine.notices.showNoMoreRetainedObjects();

      await pumpScans(tester);

      expect(find.text(LeakSentryCopy.scanStatusAllClear), findsOneWidget);
      expect(find.text(LeakSentryCopy.scanStatusAllClearBody), findsOneWidget);
    });

    testWidgets('says nothing was held when a scan was asked for and nothing was', (tester) async {
      f.engine.notices.showNoRetainedObjectsOnRequest();

      await pumpScans(tester);

      expect(find.text(LeakSentryCopy.nothingHeldOnRequest), findsOneWidget);
    });

    testWidgets('follows the notice while the tab is open', (tester) async {
      await pumpScans(tester);
      expect(find.text(LeakSentryCopy.scanStatusIdle), findsOneWidget);

      f.engine.notices.showRetainedCount(objectCount: 3, contentText: 'x', reason: const BelowThresholdEvent(3));
      await tester.pump();

      expect(find.text('3 objects held'), findsOneWidget);
    });
  });

  group('scanning now', () {
    testWidgets('asks for a scan, and says when nothing was held', (tester) async {
      f.engine.install(watchers: const []);
      await pumpScans(tester);

      await tester.tap(_scanNow);
      await tester.runAsync(f.settle);
      await tester.pump();

      expect(f.fakeGc.calls, 1, reason: 'a scan starts with a GC');
      expect(find.text(LeakSentryCopy.nothingHeldOnRequest), findsOneWidget);
      expect(f.engine.catalog.scans, isEmpty);
    });

    testWidgets('scans what is held, and lists the scan with the leak it found', (tester) async {
      f.engine.install(watchers: const []);
      final thing = _Thing();
      f.engine.objectWatcher.watch(thing, 'a thing was disposed');
      await tester.runAsync(() => f.time.elapse(const Duration(seconds: 5)));
      await pumpScans(tester);

      await tester.tap(_scanNow);
      await tester.runAsync(f.settle);
      await tester.pump();

      expect(f.engine.catalog.scans, isNotEmpty);
      expect(find.textContaining('held ·'), findsWidgets);
      expect(thing, isNotNull);
    });
  });

  group('one scan', () {
    testWidgets('says why it ran, what it was given and what it found, with where each leak came from', (tester) async {
      f.engine.install(watchers: const []);
      runScan(
        f.engine.catalog,
        'a',
        [leakReport(created: null, gap: CreationSiteGap.onlyFrameworkFrames, signature: 'framework'), leakReport(type: PageFourState, signature: 'two', count: 2)],
        held: 5,
        released: 1,
        trigger: 'user request',
      );
      await pumpScans(tester);

      await tester.tap(find.text('5 held · 2 leaks (2 new)'));
      await tester.pumpAndSettle();

      expect(find.descendant(of: find.byType(AppBar), matching: find.text(LeakSentryCopy.scanTitle)), findsOneWidget);
      expect(find.text(LeakSentryCopy.scanReason('user request')), findsOneWidget);
      expect(find.text(LeakSentryCopy.scanDetailHeld(5)), findsOneWidget);
      expect(find.text(LeakSentryCopy.scanReleased(1)), findsOneWidget);
      expect(find.text('PageThreeState'), findsOneWidget);
      expect(find.text(LeakSentryCopy.creationUnknown), findsOneWidget);
      expect(find.text('lib/main.dart:196'), findsOneWidget);
      expect(find.text(breakable('_PageThreeState.initState', after: '.')), findsOneWidget);
      expect(find.text('NEW'), findsNWidgets(2));
    });

    testWidgets('lists what it found under the leak it belongs to, each kind of object with its own place', (tester) async {
      f.engine.install(watchers: const []);
      runScan(f.engine.catalog, 'a', [
        leakReport(signature: 'page', count: 2, trace: causeTrace()),
        leakReport(
          type: PageFourState,
          signature: 'four',
          created: null,
          declared: const CreationSite(uri: 'package:leak_entry_app/main.dart', member: '_NoInitState', line: 12, column: 1),
          gap: CreationSiteGap.onlyFrameworkFrames,
          trace: causeTrace(leaked: 'PageFourState'),
        ),
        leakReport(type: AppSettings, signature: 'settings', trace: causeTrace(holder: 'AppSettings', variable: 'listeners')),
      ]);
      await pumpScans(tester);
      await tester.tap(find.textContaining('held ·'));
      await tester.pumpAndSettle();

      expect(find.text('3 held · 2 leaks (2 new)'), findsOneWidget, reason: 'objects held the same way are one leak');
      expect(find.text(breakable('PageRegistry.pages', after: '.')), findsOneWidget, reason: 'it is called as the Leaks tab calls it');
      expect(find.text('3 objects'), findsOneWidget, reason: 'two of one kind and one of another');
      expect(find.text('PageThreeState · 2 objects'), findsOneWidget);
      expect(find.text('PageFourState · 1 object'), findsOneWidget);
      expect(find.text('lib/main.dart:196'), findsNWidgets(2), reason: 'where each kind came from');
      expect(find.text('class declared at lib/main.dart:12'), findsOneWidget);
      expect(find.text(breakable('AppSettings.listeners', after: '.')), findsOneWidget);
      expect(find.text('NEW'), findsNWidgets(2), reason: 'one for each leak, not for each kind of object');
    });

    testWidgets('opens the leak whose block is tapped, not another', (tester) async {
      f.engine.install(watchers: const []);
      runScan(f.engine.catalog, 'a', [
        leakReport(signature: 'page', trace: causeTrace()),
        leakReport(type: AppSettings, signature: 'settings', trace: causeTrace(holder: 'AppSettings', variable: 'listeners')),
      ]);
      await pumpScans(tester);
      await tester.tap(find.textContaining('held ·'));
      await tester.pumpAndSettle();

      await tester.tap(find.text(breakable('AppSettings.listeners', after: '.')));
      await tester.pumpAndSettle();

      expect(find.text(LeakSentryCopy.whereCreated), findsOneWidget);
      expect(find.text(breakable('AppSettings.listeners', after: '.')), findsOneWidget, reason: 'the leak that was tapped');
      expect(find.text(breakable('PageRegistry.pages', after: '.')), findsNothing);
    });

    testWidgets('a leak it found again is not new', (tester) async {
      f.engine.install(watchers: const []);
      runScan(f.engine.catalog, 'a', [leakReport(signature: 'page', trace: causeTrace())]);
      runScan(f.engine.catalog, 'b', [leakReport(type: PageFourState, signature: 'four', trace: causeTrace(leaked: 'PageFourState'))]);
      await pumpScans(tester);
      await tester.tap(find.text('3 held · 1 leak').first);
      await tester.pumpAndSettle();

      expect(find.text('NEW'), findsNothing);
      expect(find.text('3 held · 1 leak'), findsOneWidget);
    });

    testWidgets('a leak in it opens the leak', (tester) async {
      f.engine.install(watchers: const []);
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await pumpScans(tester);
      await tester.tap(find.textContaining('held ·'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('PageThreeState'));
      await tester.pumpAndSettle();

      expect(find.text(LeakSentryCopy.whereCreated), findsOneWidget);
    });

    testWidgets('one that found nothing says so', (tester) async {
      f.engine.install(watchers: const []);
      runScan(f.engine.catalog, 'a', []);
      await pumpScans(tester);

      await tester.tap(find.text('3 held · no leaks'));
      await tester.pumpAndSettle();

      expect(find.text(LeakSentryCopy.scanDetailNoLeaks), findsOneWidget);
    });

    testWidgets('a failed one says what went wrong', (tester) async {
      f.engine.install(watchers: const []);
      f.engine.catalog.onEvent(HeapDumpFailedEvent('a', exception: StateError('no space left'), willRetryLater: true));
      await pumpScans(tester);

      await tester.tap(find.text(LeakSentryCopy.scanFailedWillRetry));
      await tester.pumpAndSettle();

      expect(find.textContaining('no space left'), findsOneWidget);
    });

    testWidgets('one that is no longer listed says so', (tester) async {
      f.engine.install(watchers: const []);
      runScan(f.engine.catalog, 'a', []);
      await pumpScans(tester);
      await tester.tap(find.text('3 held · no leaks'));
      await tester.pumpAndSettle();

      f.engine.catalog.clear();
      await tester.pump();

      expect(find.text(LeakSentryCopy.scanGone), findsOneWidget);
    });
  });

  group('whatever the screen', () {
    for (final (scale, width) in const [(1.0, 400.0), (1.5, 400.0), (1.0, 320.0), (1.5, 320.0)]) {
      testWidgets('shows scans at text scale $scale, $width wide', (tester) async {
        f.engine.install(watchers: const []);
        runScan(f.engine.catalog, 'a', [leakReport()], held: 12345);
        startScan(f.engine.catalog, 'b');
        f.engine.catalog.onEvent(const HeapAnalysisProgressEvent('b', step: AnalysisStep.findingPathsToRetainedObjects, progressPercent: 0.5));
        f.engine.catalog.onEvent(HeapDumpFailedEvent('x', exception: StateError('no space'), willRetryLater: true));

        await pumpScans(tester, textScale: scale, width: width);

        expect(tester.takeException(), isNull);
      });
    }
  });
}
