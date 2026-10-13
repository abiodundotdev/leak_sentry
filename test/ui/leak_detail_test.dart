import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/trace_builder.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/retaining_element.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/format.dart';
import 'package:leak_sentry/ui/report_text.dart';
import 'package:leak_sentry/ui/screens/leak_detail_page.dart';
import 'package:leak_sentry/ui/tokens.dart';
import 'package:leak_sentry/ui/widgets/site_line.dart';
import 'package:leak_sentry/ui/widgets/status_pill.dart';
import 'package:leak_sentry/ui/widgets/trace_timeline.dart';
import 'package:leak_sentry/utils/retaining_path_util.dart';

import '../helpers/capture_log.dart';
import '../helpers/engine_fixture.dart';
import '../helpers/leak_events.dart';
import '../helpers/leak_fixtures.dart';
import '../helpers/pump_ui.dart';
import '../helpers/vm_fixtures.dart';

RetainingPathInfo _path(String shape) => RetainingPathUtil.describe(VmFixture.load(shape).path);

const _declared = CreationSite(uri: 'package:leak_entry_app/main.dart', member: '_NoInitState', line: 12, column: 1);

void main() {
  late EngineFixture f;
  late List<String> copied;

  setUp(() {
    captureLog();
    f = EngineFixture();
  });

  tearDown(() => f.engine.dispose());

  /// Shows the leak the catalog has, found by one scan of [leaks].
  Future<LeakGroup> open(
    WidgetTester tester,
    List<LeakReport> leaks, {
    double textScale = 1.0,
    double width = 400,
    int index = 0,
  }) async {
    copied = captureClipboard(tester);
    runScan(f.engine.catalog, 'a', leaks);
    final group = f.engine.catalog.groups[index];
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(MaterialApp(home: LeakDetailPage(engine: f.engine, groupId: group.id)));
    return group;
  }

  group('what the leak is', () {
    testWidgets('has the name of what leaked, how many, and when', (tester) async {
      await open(tester, [leakReport(count: 3)]);

      expect(find.text('PageThreeState'), findsOneWidget);
      expect(find.text('3 objects · seen just now'), findsOneWidget);
    });

    testWidgets('reads: opening it marks it read', (tester) async {
      final group = await open(tester, [leakReport()]);
      expect(group.isUnread, isTrue);

      await tester.pump();

      expect(f.engine.catalog.groupById(group.id)!.isUnread, isFalse);
    });

    testWidgets('a leak that has been cleared says so, instead of showing nothing', (tester) async {
      await open(tester, [leakReport()]);

      f.engine.clearLeaks();
      await tester.pump();

      expect(find.text(LeakSentryCopy.leakCleared), findsOneWidget);
    });
  });

  group('a leak whose path was worked out', () {
    testWidgets('is called by its likely cause, and says what it holds', (tester) async {
      await open(tester, [leakReport(trace: causeTrace())]);

      expect(find.text(breakable('PageRegistry.pages', after: '.')), findsOneWidget);
      expect(find.text('Holds PageThreeState'), findsOneWidget);
      expect(find.text('PageThreeState'), findsNothing, reason: 'the type of what leaked is not its name any more');
    });

    testWidgets('names every kind of object that is held that way, and tells the instances apart by it', (tester) async {
      final grouped = EngineFixture(catalog: LeakCatalog(now: f.wallNow, groupKey: (report) => report.reason));
      addTearDown(grouped.engine.dispose);
      runScan(grouped.engine.catalog, 'a', [
        leakReport(reason: 'held', trace: causeTrace()),
        leakReport(type: PageFourState, reason: 'held', signature: 'two', trace: causeTrace(leaked: 'PageFourState')),
      ]);
      await tester.pumpWidget(MaterialApp(home: LeakDetailPage(engine: grouped.engine, groupId: grouped.engine.catalog.groups.single.id)));

      expect(find.text('Holds PageThreeState and\u00A0PageFourState'), findsOneWidget, reason: 'a line may break before the "and", not after it');
      expect(find.textContaining('Instance 1 of 2 · PageThreeState · 1 object'), findsOneWidget);
      expect(find.textContaining('Instance 2 of 2 · PageFourState · 1 object'), findsOneWidget);
    });

    testWidgets('shows what each step of the path is, and why', (tester) async {
      final path = _path('state_static_registry');
      await open(tester, [leakReport(path: path, trace: TraceBuilder.build(path, leakedReason: 'it was disposed'))]);

      expect(find.byType(StatusPill), findsNWidgets(3));
      expect(find.text(LeakSentryCopy.statusInUse), findsOneWidget);
      expect(find.text(LeakSentryCopy.statusUnclear), findsOneWidget);
      expect(find.text(LeakSentryCopy.statusShouldBeGone), findsOneWidget);
      expect(find.text('Expected to be gone: it was disposed'), findsOneWidget);
    });

    testWidgets('says nothing of what a step is when nobody has looked: only the path', (tester) async {
      await open(tester, [leakReport(path: _path('state_static_registry'))]);

      expect(find.byType(TraceTimeline), findsOneWidget);
      expect(find.byType(StatusPill), findsNothing);
    });

    testWidgets('says when LeakSentry itself holds it', (tester) async {
      await open(tester, [leakReport(trace: causeTrace(internal: true))]);

      expect(find.text(LeakSentryCopy.tagInternal), findsOneWidget);
    });

    testWidgets('does not say so of what the app holds', (tester) async {
      await open(tester, [leakReport(trace: causeTrace())]);

      expect(find.text(LeakSentryCopy.tagInternal), findsNothing);
    });
  });

  group('where it was created', () {
    testWidgets('is the first thing: the file and line, the member, and the package', (tester) async {
      await open(tester, [leakReport()]);

      expect(find.text(LeakSentryCopy.whereCreated), findsOneWidget);
      expect(find.text('Created at'), findsOneWidget);
      expect(find.text('lib/main.dart:196'), findsOneWidget);
      expect(find.text('_PageThreeState.initState'), findsOneWidget);
      expect(find.text('package:leak_entry_app'), findsOneWidget);
      expect(tester.getTopLeft(find.text(LeakSentryCopy.whereCreated)).dy, lessThan(tester.getTopLeft(find.text(LeakSentryCopy.pathTitle)).dy));
    });

    testWidgets('copies the whole location when tapped', (tester) async {
      await open(tester, [leakReport()]);

      await tester.tap(find.byType(SiteLine));
      await tester.pump();

      expect(copied, ['package:leak_entry_app/main.dart:196:11']);
      expect(find.text(LeakSentryCopy.locationCopied), findsOneWidget);
    });

    testWidgets('says where an object was handed to the watcher, when that is all it knows', (tester) async {
      await open(tester, [leakReport(created: null, watched: const CreationSite(uri: 'package:leak_entry_app/main.dart', member: 'build', line: 77, column: 5))]);

      expect(find.text('Watched at'), findsOneWidget);
      expect(find.text('lib/main.dart:77'), findsOneWidget);
      expect(find.text(LeakSentryCopy.creationUnknown), findsNothing);
    });

    testWidgets('says why the creation site is not known, and where the class is declared', (tester) async {
      await open(tester, [leakReport(created: null, gap: CreationSiteGap.onlyFrameworkFrames, declared: _declared)]);

      expect(find.text(LeakSentryCopy.creationUnknown), findsOneWidget);
      expect(find.text(LeakSentryCopy.creationGap(CreationSiteGap.onlyFrameworkFrames)), findsOneWidget);
      expect(find.text('Class declared at'), findsOneWidget);
      expect(find.text('lib/main.dart:12'), findsOneWidget);
      expect(find.text('_NoInitState'), findsOneWidget);
    });

    testWidgets('says where it was created before where it was watched, when a report has both', (tester) async {
      await open(tester, [leakReport(watched: const CreationSite(uri: 'package:leak_entry_app/main.dart', member: 'build', line: 77, column: 5))]);

      expect(find.text('Created at'), findsOneWidget);
      expect(find.text('Watched at'), findsNothing);
    });

    testWidgets('draws the next best place in the cautious colour, and the real one in mint', (tester) async {
      await open(tester, [leakReport()]);
      expect(tester.widget<Text>(find.text('lib/main.dart:196')).style!.color, LeakSentryColors.accent);

      await open(tester, [leakReport(signature: 'watched', created: null, watched: const CreationSite(uri: 'package:leak_entry_app/main.dart', member: 'build', line: 77, column: 5))], index: 1);
      expect(tester.widget<Text>(find.text('lib/main.dart:77')).style!.color, LeakSentryColors.caution);
    });

    testWidgets('draws where the class is declared in the cautious colour too', (tester) async {
      await open(tester, [leakReport(created: null, gap: CreationSiteGap.onlyFrameworkFrames, declared: _declared)]);

      expect(tester.widget<Text>(find.text('lib/main.dart:12')).style!.color, LeakSentryColors.caution);
    });

    testWidgets('still says it is not known when it has no reason to give', (tester) async {
      await open(tester, [leakReport(created: null)]);

      expect(find.text(LeakSentryCopy.creationUnknown), findsOneWidget);
      expect(find.text(LeakSentryCopy.creationUnknownNoReason), findsOneWidget);
      expect(find.byType(SiteLine), findsNothing);
    });

    testWidgets('lists every place a leak came from, when it came from several', (tester) async {
      // The two signatures are one leak when the catalog is told they are.
      final grouped = EngineFixture(catalog: LeakCatalog(now: f.wallNow, groupKey: (report) => report.reason));
      addTearDown(grouped.engine.dispose);
      runScan(grouped.engine.catalog, 'a', [
        leakReport(signature: 'one', count: 2),
        leakReport(signature: 'two', created: const CreationSite(uri: 'package:leak_entry_app/other.dart', member: 'make', line: 9, column: 3)),
      ]);
      await tester.pumpWidget(MaterialApp(home: LeakDetailPage(engine: grouped.engine, groupId: grouped.engine.catalog.groups.single.id)));

      expect(find.byType(SiteLine), findsNWidgets(2));
      expect(find.text('lib/main.dart:196'), findsOneWidget);
      expect(find.text('lib/other.dart:9'), findsOneWidget);
      expect(find.textContaining('Instance 1 of 2'), findsOneWidget);
      expect(find.textContaining('Instance 2 of 2'), findsOneWidget);
    });
  });

  group('what holds it', () {
    testWidgets('is a timeline of the path from the root to the leaked object', (tester) async {
      await open(tester, [leakReport(path: _path('state_listener_tearoff'))]);

      expect(find.byType(TraceTimeline), findsOneWidget);
      expect(find.text('Starts at: a static variable'), findsOneWidget);
      expect(find.text('ChangeNotifier'), findsOneWidget);
      expect(find.text('._listeners'), findsOneWidget);
      expect(find.text(breakable('_ListenerPageState._onChange', after: '.')), findsOneWidget);
      expect(find.text('receiver'), findsOneWidget);
      expect(find.text('_ListenerPageState'), findsOneWidget);
    });

    testWidgets('is the path of the instance that was seen last, when there are several', (tester) async {
      var clock = EngineFixture.epoch;
      final catalog = LeakCatalog(now: () => clock, groupKey: (report) => report.reason);
      final grouped = EngineFixture(catalog: catalog);
      addTearDown(grouped.engine.dispose);
      runScan(catalog, 'a', [leakReport(signature: 'old', path: _path('static_class_field'))]);
      clock = clock.add(const Duration(minutes: 5));
      runScan(
        catalog,
        'b',
        [
          leakReport(
            signature: 'new',
            created: const CreationSite(uri: 'package:leak_entry_app/other.dart', member: 'make', line: 9, column: 3),
            path: _path('state_listener_tearoff'),
          ),
        ],
      );
      expect(catalog.groups.single.instances, hasLength(2));

      await tester.pumpWidget(MaterialApp(home: LeakDetailPage(engine: grouped.engine, groupId: catalog.groups.single.id)));

      expect(find.text(breakable('_ListenerPageState._onChange', after: '.')), findsOneWidget, reason: 'the path of the later instance');
      expect(find.text('Holder'), findsNothing, reason: 'not the path of the earlier one');
      expect(find.text(LeakSentryCopy.pathOfLatest(2)), findsOneWidget);
    });

    testWidgets('is the path of the instance seen last that has one, when a later scan found none', (tester) async {
      var clock = EngineFixture.epoch;
      final catalog = LeakCatalog(now: () => clock, groupKey: (report) => report.reason);
      final grouped = EngineFixture(catalog: catalog);
      addTearDown(grouped.engine.dispose);
      runScan(catalog, 'a', [leakReport(signature: 'old', path: _path('static_class_field'))]);
      clock = clock.add(const Duration(minutes: 5));
      runScan(
        catalog,
        'b',
        [
          leakReport(
            signature: 'new',
            created: const CreationSite(uri: 'package:leak_entry_app/other.dart', member: 'make', line: 9, column: 3),
            pathGap: RetainingPathGap.lookupLimitReached,
          ),
        ],
      );
      expect(catalog.groups.single.instances, hasLength(2));

      await tester.pumpWidget(MaterialApp(home: LeakDetailPage(engine: grouped.engine, groupId: catalog.groups.single.id)));

      expect(find.byType(TraceTimeline), findsOneWidget);
      expect(find.text('Holder'), findsOneWidget, reason: 'the path the earlier instance had');
      expect(find.text(LeakSentryCopy.pathGap(RetainingPathGap.lookupLimitReached)), findsNothing);
    });

    testWidgets('says how many steps the VM left out', (tester) async {
      const info = RetainingPathInfo(
        gcRootType: 'user global',
        hops: ['a', 'b'],
        elements: [
          RetainingElement(kind: RetainingElementKind.instance, className: 'Leaky'),
          RetainingElement(kind: RetainingElementKind.instance, className: 'Link', field: 'next'),
        ],
        totalLength: 30,
      );

      await open(tester, [leakReport(path: info)]);

      expect(find.text(LeakSentryCopy.moreSteps(28)), findsOneWidget);
    });

    testWidgets('says why there is no path, when there is none', (tester) async {
      await open(tester, [leakReport(pathGap: RetainingPathGap.noVmService)]);

      expect(find.byType(TraceTimeline), findsNothing);
      expect(find.text(LeakSentryCopy.pathGap(RetainingPathGap.noVmService)), findsOneWidget);
    });

    testWidgets('says so even when it does not know why', (tester) async {
      await open(tester, [leakReport()]);

      expect(find.text(LeakSentryCopy.pathUnknown), findsOneWidget);
    });
  });

  group('a resource that was never closed', () {
    testWidgets('says where it was acquired, which one it is, and has no path to show', (tester) async {
      f.engine.catalog.addResourceLeak(
        leakReport(
          type: PageFourState,
          reason: 'PageFour.controller',
          signature: 'res',
          confidence: LeakConfidence.resourceNeverClosed,
          created: const CreationSite(uri: 'package:leak_entry_app/main.dart', member: '_PageFourState.initState', line: 251, column: 5),
          acquiredAt: StackTrace.fromString('#0      _PageFourState.initState (package:leak_entry_app/main.dart:251:5)\n'),
        ),
      );
      await tester.pumpWidget(MaterialApp(home: LeakDetailPage(engine: f.engine, groupId: f.engine.catalog.groups.single.id)));

      expect(find.text(breakable('PageFour.controller', after: '.')), findsOneWidget, reason: 'its label is what names it');
      expect(find.text('PageFourState'), findsOneWidget);
      expect(find.text('Acquired at'), findsOneWidget);
      expect(find.text('lib/main.dart:251'), findsOneWidget);
      expect(find.text(LeakSentryCopy.resourceExplanation), findsOneWidget);
      expect(find.byType(TraceTimeline), findsNothing);
      expect(find.text(LeakSentryCopy.pathUnknown), findsNothing);
    });
  });

  group('the report', () {
    testWidgets('is copied, and says so', (tester) async {
      final group = await open(tester, [leakReport(path: _path('static_class_field'))]);

      await tester.tap(find.byTooltip(LeakSentryCopy.copyReport));
      await tester.pump();

      expect(copied.single, buildLeakReport(group, now: f.engine.catalog.now()));
      expect(copied.single, startsWith('LeakSentry report'));
      expect(copied.single, contains('Created at: package:leak_entry_app/main.dart:196:11'));
      expect(find.text(LeakSentryCopy.reportCopied), findsOneWidget);
    });

    testWidgets('is printed to the console, and says so', (tester) async {
      final printed = <String>[];
      final previous = debugPrint;
      final group = await open(tester, [leakReport(path: _path('static_class_field'))]);
      // flutter_test checks that this is put back before any tear-down runs.
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      try {
        await tester.tap(find.byTooltip(LeakSentryCopy.printReport));
        await tester.pump();
      } finally {
        debugPrint = previous;
      }

      expect(printed.single, buildLeakReport(group, now: f.engine.catalog.now()));
      expect(find.text(LeakSentryCopy.reportPrinted), findsOneWidget);
    });

    testWidgets('has the actions in the app bar, and not when the leak is gone', (tester) async {
      await open(tester, [leakReport()]);
      expect(find.descendant(of: find.byType(AppBar), matching: find.byTooltip(LeakSentryCopy.copyReport)), findsOneWidget);
      expect(find.descendant(of: find.byType(AppBar), matching: find.byTooltip(LeakSentryCopy.printReport)), findsOneWidget);

      f.engine.clearLeaks();
      await tester.pump();

      expect(find.byTooltip(LeakSentryCopy.copyReport), findsNothing);
      expect(find.byTooltip(LeakSentryCopy.printReport), findsNothing);
    });
  });

  group('how to read the path', () {
    testWidgets('is said above the timeline, with what the statuses mean', (tester) async {
      await open(tester, [leakReport(path: _path('static_class_field'))]);

      expect(find.text(LeakSentryCopy.pathHint), findsOneWidget);
      expect(tester.getTopLeft(find.text(LeakSentryCopy.pathHint)).dy, lessThan(tester.getTopLeft(find.text(LeakSentryCopy.startsAt('user global'))).dy));
    });

    testWidgets('is not said when there is no path to read', (tester) async {
      await open(tester, [leakReport()]);

      expect(find.text(LeakSentryCopy.pathHint), findsNothing);
    });

    testWidgets('names the reference to start with, and no other', (tester) async {
      final path = _path('state_static_registry');
      await open(tester, [leakReport(path: path, trace: TraceBuilder.build(path, leakedReason: 'it was disposed'))]);

      expect(find.text(LeakSentryCopy.startHere), findsOneWidget);
      expect(find.text(LeakSentryCopy.likelyCause), findsOneWidget, reason: 'the second likely cause, which is not where to start');
    });

    testWidgets('says where the leaked object was created, under it at the end of the path', (tester) async {
      final path = _path('state_static_registry');
      await open(tester, [leakReport(path: path, trace: TraceBuilder.build(path))]);

      expect(find.text(breakable('created at lib/main.dart:196', after: '/:')), findsOneWidget);
    });

    testWidgets('says where it was handed to the watcher, or where its class is declared, when that is all it knows', (tester) async {
      final path = _path('state_static_registry');
      await open(tester, [leakReport(created: null, declared: _declared, path: path, trace: TraceBuilder.build(path))]);

      expect(find.text(breakable('class declared at lib/main.dart:12', after: '/:')), findsOneWidget);
    });

    testWidgets('says where it was created, not where it was watched, when a report has both', (tester) async {
      final path = _path('state_static_registry');
      await open(
        tester,
        [
          leakReport(
            watched: const CreationSite(uri: 'package:leak_entry_app/main.dart', member: 'build', line: 77, column: 5),
            path: path,
            trace: TraceBuilder.build(path),
          ),
        ],
      );

      expect(find.text(breakable('created at lib/main.dart:196', after: '/:')), findsOneWidget);
      expect(find.textContaining('watched at'), findsNothing);
    });

    testWidgets('says nothing under it when no place is known', (tester) async {
      final path = _path('state_static_registry');
      await open(tester, [leakReport(created: null, path: path, trace: TraceBuilder.build(path))]);

      expect(find.textContaining('created at'), findsNothing);
      expect(find.textContaining('declared at'), findsNothing);
    });
  });

  group('whatever the screen', () {
    for (final (scale, width) in const [(1.0, 400.0), (1.5, 400.0), (1.0, 320.0), (1.5, 320.0)]) {
      testWidgets('shows a long path at text scale $scale, $width wide', (tester) async {
        await open(
          tester,
          [leakReport(created: const CreationSite(uri: 'package:a_package_with_a_rather_long_name/some/nested/directory/a_long_file_name.dart', member: '_AnExtremelyLongNamedStateClassForTestingState.initState', line: 12345, column: 7), path: _path('state_timer_closure'))],
          textScale: scale,
          width: width,
        );

        expect(tester.takeException(), isNull);
        expect(find.byType(TraceTimeline), findsOneWidget);
      });

      testWidgets('shows a long path with what each step is and why, at text scale $scale, $width wide', (tester) async {
        final path = _path('state_timer_closure');
        await open(
          tester,
          [leakReport(path: path, trace: TraceBuilder.build(path, leakedReason: 'a State that was disposed, which is a rather long thing to say'))],
          textScale: scale,
          width: width,
        );

        expect(tester.takeException(), isNull);
        expect(find.byType(StatusPill), findsNWidgets(10));
      });
    }
  });
}
