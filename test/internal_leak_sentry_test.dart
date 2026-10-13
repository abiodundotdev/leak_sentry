import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/heap_analysis.dart';
import 'package:leak_sentry/core/gc_trigger.dart';
import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';
import 'package:leak_sentry/core/leak_sentry_log.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/object_watcher/default_watchers.dart';
import 'package:leak_sentry/object_watcher/deletable_object_reporter.dart';
import 'package:leak_sentry/object_watcher/installable_watcher.dart';

import 'helpers/capture_log.dart';
import 'helpers/engine_fixture.dart';
import 'helpers/force_gc.dart';

/// A State that reports its creation the way Flutter's does: from initState().
class _TestState extends State<StatefulWidget> {
  @override
  void initState() {
    super.initState();
  }

  void runInitState() => initState();

  @override
  Widget build(BuildContext context) => const SizedBox();
}

/// Creates a State the way the framework does, reporting it from initState().
_TestState _createState() => _TestState()..runInitState();

void _dispose(Object object) =>
    FlutterMemoryAllocations.instance.dispatchObjectEvent(ObjectDisposed(object: object));

class _ForceGcTrigger implements GcTrigger {
  @override
  Future<bool> runGc() async {
    await forceGc();
    return true;
  }
}

class _FailingWatcher implements InstallableWatcher {
  @override
  void install() => throw StateError('cannot install');

  @override
  void uninstall() {}
}

class _CountingWatcher implements InstallableWatcher {
  int installs = 0;
  int uninstalls = 0;

  @override
  void install() => installs++;

  @override
  void uninstall() => uninstalls++;
}

void main() {
  late LeakSentryLogger? previousLogger;
  late List<EngineFixture> fixtures;

  EngineFixture fixture({
    bool release = false,
    bool web = false,
    GcTrigger? gc,
    String? Function()? testEnvironment,
    bool overrideTestEnvironment = true,
    Duration listenerWait = const Duration(seconds: 10),
    Duration analysisWait = const Duration(seconds: 60),
  }) {
    final created = EngineFixture(
      release: release,
      web: web,
      gc: gc,
      testEnvironment: testEnvironment,
      overrideTestEnvironment: overrideTestEnvironment,
      listenerWait: listenerWait,
      analysisWait: analysisWait,
    );
    fixtures.add(created);
    return created;
  }

  setUp(() {
    previousLogger = LeakSentryLog.logger;
    LeakSentryLog.logger = null;
    fixtures = [];
  });

  tearDown(() {
    for (final created in fixtures) {
      created.engine.dispose();
    }
    LeakSentryLog.logger = previousLogger;
  });

  group('installing', () {
    test('is off until installed, and the retained delay is five seconds unless set', () {
      final f = fixture();
      expect(f.engine.isInstalled, isFalse);
      expect(f.engine.retainedDelay, const Duration(seconds: 5));

      f.engine.install();

      expect(f.engine.isInstalled, isTrue);
      expect(f.engine.retainedDelay, const Duration(seconds: 5));
    });

    test('uses the retained delay it was given', () async {
      final f = fixture();
      f.engine.install(retainedDelay: const Duration(seconds: 2), watchers: const []);
      final object = Object();

      f.engine.objectWatcher.watch(object, 'why');
      await f.time.elapse(const Duration(seconds: 2));

      expect(f.engine.retainedObjectCount, 1);
    });

    test('a second install throws, and says where the first one was', () {
      final f = fixture();
      f.engine.install();

      expect(
        f.engine.install,
        throwsA(isA<StateError>().having((e) => e.message, 'message', allOf(contains('already installed'), contains('first installed here')))),
      );
      expect(f.engine.installObjectWatcher, throwsStateError);
      expect(f.engine.isInstalled, isTrue);
    });

    test('a negative retained delay is refused and leaves nothing installed', () {
      final f = fixture();

      expect(() => f.engine.install(retainedDelay: const Duration(seconds: -1)), throwsArgumentError);

      expect(f.engine.isInstalled, isFalse);
      expect(f.visibility.isStarted, isFalse);
      f.engine.install();
      expect(f.engine.isInstalled, isTrue);
    });

    test('a disposed instance cannot be installed', () {
      final f = fixture();
      f.engine.dispose();

      expect(f.engine.install, throwsStateError);
    });

    test('starts logging in a debug build, unless something already logs', () {
      final f = fixture();
      expect(LeakSentryLog.logger, isNull);

      f.engine.install();
      expect(LeakSentryLog.logger, isA<ConsoleLeakSentryLogger>());

      f.engine.dispose();
      final custom = CapturingLogger();
      LeakSentryLog.logger = custom;
      final g = fixture();
      g.engine.install();
      expect(LeakSentryLog.logger, same(custom));
    });

    test('says, once the app had the chance to configure it, that it is ready', () async {
      final log = captureLog();
      final f = fixture();
      f.engine.install();
      expect(log.lines.where((line) => line.contains('ready to detect')), isEmpty, reason: 'logged after startup');

      await f.time.elapse(Duration.zero);

      expect(log.lines, contains('LeakSentry is running and ready to detect memory leaks.'));
    });

    test('says why it is not ready when the config turns dumping off', () async {
      final log = captureLog();
      final f = fixture();
      f.engine.config = const LeakSentryConfig(dumpHeap: false);
      f.engine.install();

      await f.time.elapse(Duration.zero);

      expect(log.lines, contains('LeakSentry is currently disabled: LeakSentryConfig.dumpHeap is set to false.'));
    });

    test('rolls back completely when a watcher fails to install, so it can be tried again', () {
      final f = fixture();
      final before = _CountingWatcher();

      expect(
        () => f.engine.install(watchers: [before, _FailingWatcher()]),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'cannot install')),
      );

      expect(f.engine.isInstalled, isFalse);
      expect(before.installs, 1);
      expect(before.uninstalls, 1);
      expect(f.visibility.isStarted, isFalse);
      f.engine.install(watchers: [before]);
      expect(f.engine.isInstalled, isTrue);
    });

    test('installs the watchers it is given instead of the defaults', () async {
      final f = fixture();
      final watcher = _CountingWatcher();
      f.engine.install(watchers: [watcher]);

      expect(watcher.installs, 1);
      final state = _TestState();
      _dispose(state);
      expect(f.engine.objectWatcher.trackedObjectCount, 0, reason: 'the default State watcher is not installed');
      expect(state, isNotNull);
    });
  });

  group('in a release build', () {
    test('install is refused, with instructions, and installs nothing', () {
      final f = fixture(release: true);

      expect(
        f.engine.install,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('LeakSentry in a release build'), contains('allowInRelease'), contains('installObjectWatcher')),
          ),
        ),
      );

      expect(f.engine.isInstalled, isFalse);
      expect(f.visibility.isStarted, isFalse);
      expect(LeakSentryLog.logger, isNull);
    });

    test('install works when it is allowed, and stays quiet', () {
      final f = fixture(release: true);

      f.engine.install(allowInRelease: true);

      expect(f.engine.isInstalled, isTrue);
      expect(LeakSentryLog.logger, isNull, reason: 'only debug and profile builds log');
    });

    test('the object watcher can still be installed, and counts retained objects', () async {
      final f = fixture(release: true);
      f.engine.installObjectWatcher(watchers: const []);
      final object = Object();

      f.engine.objectWatcher.watch(object, 'why');
      await f.time.elapse(const Duration(seconds: 5));

      expect(f.engine.retainedObjectCount, 1);
      expect(f.fakeGc.calls, 0, reason: 'no heap dump machinery is loaded');
      expect(f.visibility.isStarted, isFalse);
    });
  });

  group('installIfNeeded', () {
    test('installs once', () {
      final f = fixture();

      expect(f.engine.installIfNeeded(), isTrue);
      expect(f.engine.installIfNeeded(), isFalse);
      expect(f.engine.isInstalled, isTrue);
    });

    test('does nothing after an explicit install', () {
      final f = fixture();
      f.engine.installObjectWatcher();

      expect(f.engine.installIfNeeded(), isFalse);
    });

    test('does nothing in a release build', () {
      final f = fixture(release: true);

      expect(f.engine.installIfNeeded(), isFalse);
      expect(f.engine.isInstalled, isFalse);
    });

    test('does nothing in a test environment, where its timers would fail widget tests', () {
      final f = fixture(testEnvironment: () => 'FLUTTER_TEST');

      expect(f.engine.installIfNeeded(), isFalse);
      expect(f.engine.isInstalled, isFalse);
    });
  });

  group('watching', () {
    test('before install is ignored, not an error', () {
      final log = captureLog();
      final f = fixture();

      expect(() => f.engine.objectWatcher.watch(Object(), 'why'), returnsNormally);

      expect(f.engine.objectWatcher.trackedObjectCount, 0);
      expect(f.time.pendingCount, 0);
      expect(log.lines, contains('Ignoring a watched object: LeakSentry is not installed'));
    });

    test('after dispose is ignored again', () {
      final f = fixture();
      f.engine.install();
      f.engine.dispose();

      f.engine.objectWatcher.watch(Object(), 'why');

      expect(f.engine.objectWatcher.trackedObjectCount, 0);
    });

    test('the default watchers are State, Route, ChangeNotifier and AnimationController', () {
      final f = fixture();

      final watchers = f.engine.defaultWatchers();

      expect(watchers.map((watcher) => watcher.runtimeType), [
        StateWatcher,
        RouteWatcher,
        ChangeNotifierWatcher,
        AnimationControllerWatcher,
      ]);
    });

    test('the default watchers report to the reporter they are given', () {
      final f = fixture();
      final reported = <String>[];
      final watchers = f.engine.defaultWatchers(_ReasonReporter(reported));
      f.engine.install(watchers: watchers);

      _dispose(_TestState());

      expect(reported, ['_TestState received State#dispose() callback']);
      expect(f.engine.objectWatcher.trackedObjectCount, 0);
    });

    test('a reporter that filters keeps unwanted objects out', () async {
      final f = fixture();
      final reporter = f.engine.objectWatcher.filteringInstances<_TestState>((_) => false);
      f.engine.install(watchers: f.engine.defaultWatchers(reporter));

      _dispose(_TestState());

      expect(f.engine.objectWatcher.trackedObjectCount, 0);
    });

    test('disposing uninstalls the watchers', () {
      final f = fixture();
      final reported = <String>[];
      f.engine.install(watchers: f.engine.defaultWatchers(_ReasonReporter(reported)));
      _dispose(_TestState());
      expect(reported, hasLength(1), reason: 'the watcher is listening');

      f.engine.dispose();
      _dispose(_TestState());

      // The reporter is called by the watcher itself, so this tells a watcher that
      // was uninstalled from a watch that was merely ignored.
      expect(reported, hasLength(1));
    });

    test('disposing uninstalls every watcher it was given, and only once', () {
      final f = fixture();
      final first = _CountingWatcher();
      final second = _CountingWatcher();
      f.engine.install(watchers: [first, second]);

      f.engine.dispose();
      f.engine.dispose();

      expect([first.uninstalls, second.uninstalls], [1, 1]);
    });

    test('disposing cancels a check that is waiting to run again', () async {
      final f = fixture();
      f.engine.install();
      final state = _createState();
      _dispose(state);
      await f.time.elapse(const Duration(seconds: 5)); // one retained object: below the threshold, so it rechecks
      expect(f.time.pendingDelays, [const Duration(seconds: 2)]);

      f.engine.dispose();

      expect(f.time.pendingCount, 0);
      await f.time.elapse(const Duration(minutes: 2));
      expect(f.fakeGc.calls, 1);
      expect(state, isNotNull);
    });

    test('disposing stops the trigger, drops what is waiting, and stops hearing about retained objects', () async {
      final f = fixture();
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
      f.engine.install();
      final state = _createState();
      _dispose(state);
      await f.time.elapse(Duration.zero); // lets the "ready" log, which install schedules, run
      expect(f.time.pendingCount, 1, reason: 'the retained delay is running');

      f.engine.dispose();

      expect(f.time.pendingCount, 0);
      expect(f.engine.objectWatcher.trackedObjectCount, 0);
      f.engine.objectWatcher.watch(Object(), 'late');
      await f.time.elapse(const Duration(seconds: 30));
      expect(f.fakeGc.calls, 0);
      expect(f.eventsOf<HeapDumpEvent>(), isEmpty);
      expect(state, isNotNull);
    });

    test('a disposed State that stays reachable is retained after the delay', () async {
      final f = fixture();
      f.engine.installObjectWatcher();
      final state = _TestState();

      _dispose(state);
      await f.time.elapse(const Duration(milliseconds: 4999));
      expect(f.engine.retainedObjectCount, 0);
      await f.time.elapse(const Duration(milliseconds: 1));

      expect(f.engine.retainedObjectCount, 1);
      expect(f.engine.objectWatcher.retainedObjects.single, same(state));
    });
  });

  group('from a retained object to a reported leak', () {
    test('forces a GC, dumps the heap, analyzes it, and reports the leak with where it was created', () async {
      final f = fixture();
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
      f.engine.install();
      final state = _createState();

      _dispose(state);
      await f.time.elapse(const Duration(seconds: 5));

      expect(f.fakeGc.calls, 1);
      final report = f.engine.hub.leakHistory.single;
      expect(report.type, _TestState);
      expect(report.reason, '_TestState received State#dispose() callback');
      expect(report.confidence, LeakConfidence.retainedAfterGc);
      expect(report.creationSite?.member, '_TestState.initState');
      expect(report.creationSite?.uri, endsWith('internal_leak_sentry_test.dart'));
      expect(report.retainingPath, same(f.vm.path));
      expect(report.objectId, 'objects/${identityHashCode(state)}');
      expect(report.occurrenceCount, 1);
      expect(state, isNotNull);
    });

    test('sends the events in order, and the analysis result carries the new leaks', () async {
      final f = fixture();
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
      f.engine.install();
      final state = _createState();

      _dispose(state);
      await f.time.elapse(const Duration(seconds: 5));

      expect(f.events.map((event) => event.runtimeType).toSet().toList(), [
        DumpingHeapEvent,
        HeapDumpEvent,
        HeapAnalysisProgressEvent,
        HeapAnalysisSucceededEvent,
      ]);
      final succeeded = f.eventsOf<HeapAnalysisSucceededEvent>().single;
      expect(succeeded.newLeakSignatures, hasLength(1));
      expect(succeeded.heapAnalysis.leaks.single.reason, '_TestState received State#dispose() callback');
      expect(f.eventsOf<HeapDumpEvent>().single.uniqueId, succeeded.uniqueId);
      expect(f.eventsOf<HeapAnalysisProgressEvent>().map((event) => event.step), [
        AnalysisStep.findingRetainedObjects,
        AnalysisStep.findingPathsToRetainedObjects,
        AnalysisStep.buildingLeakTraces,
        AnalysisStep.reportingHeapAnalysis,
      ]);
      expect(state, isNotNull);
    });

    test('five leaks while the app is visible are enough to dump, fewer wait', () async {
      final f = fixture();
      f.engine.install();
      final states = List.generate(4, (_) => _createState());

      for (final state in states) {
        _dispose(state);
      }
      await f.time.elapse(const Duration(seconds: 5));
      expect(f.eventsOf<HeapDumpEvent>(), isEmpty);
      expect(f.notifier.calls.last, 'retained(4, "App visible, waiting until 5 retained objects")');

      final fifth = _createState();
      _dispose(fifth);
      // Retained five seconds later, and noticed by the next recheck, which
      // comes every two seconds.
      await f.time.elapse(const Duration(seconds: 6));

      expect(f.eventsOf<HeapDumpEvent>(), hasLength(1));
      expect(f.eventsOf<HeapDumpEvent>().single.dump.objects, hasLength(5));
      expect(states, hasLength(4));
      expect(fifth, isNotNull);
    });

    test('going to the background dumps what is retained, however little', () async {
      final f = fixture();
      f.engine.install();
      final state = _createState();
      _dispose(state);
      await f.time.elapse(const Duration(seconds: 5));
      expect(f.eventsOf<HeapDumpEvent>(), isEmpty);

      f.visibility.emit(false);
      await f.time.elapse(const Duration(seconds: 6));

      expect(f.eventsOf<HeapDumpEvent>().single.reason, '1 retained objects, app is not visible');
      expect(f.engine.hub.leakHistory, hasLength(1));
      expect(state, isNotNull);
    });

    test('an object reported once is not reported by the next dump', () async {
      final f = fixture();
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
      f.engine.install();
      final first = _createState();
      _dispose(first);
      await f.time.elapse(const Duration(seconds: 5));
      expect(f.eventsOf<HeapDumpEvent>().single.dump.objects, hasLength(1));
      expect(f.engine.retainedObjectCount, 0, reason: 'a dump forgets what it contained');

      await f.time.elapse(const Duration(seconds: 61));
      final second = _createState();
      _dispose(second);
      await f.time.elapse(const Duration(seconds: 5));

      final dumps = f.eventsOf<HeapDumpEvent>().toList();
      expect(dumps, hasLength(2));
      expect(dumps.last.dump.objects, hasLength(1));
      expect(first, isNotNull);
      expect(second, isNotNull);
    });

    test('the same leak found by two dumps is one report with a higher count', () async {
      final f = fixture();
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
      f.engine.install();
      final first = _createState();
      _dispose(first);
      await f.time.elapse(const Duration(seconds: 5));
      await f.time.elapse(const Duration(seconds: 61));
      final second = _createState();
      _dispose(second);
      await f.time.elapse(const Duration(seconds: 5));

      expect(f.eventsOf<HeapDumpEvent>(), hasLength(2));
      expect(f.engine.hub.leakHistory, hasLength(1), reason: 'both were created by the same line');
      expect(f.engine.hub.leakHistory.single.occurrenceCount, 2);
      expect(f.eventsOf<HeapAnalysisSucceededEvent>().last.newLeakSignatures, isEmpty, reason: 'not new the second time');
      expect(first, isNotNull);
      expect(second, isNotNull);
    });

    test('a leak created in a loop is one leak with a count', () async {
      final f = fixture();
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 3);
      f.engine.install();
      final states = [for (var i = 0; i < 3; i++) _createState()];

      states.forEach(_dispose);
      await f.time.elapse(const Duration(seconds: 5));

      expect(f.engine.hub.leakHistory, hasLength(1));
      expect(f.engine.hub.leakHistory.single.occurrenceCount, 3);
      expect(f.vm.retainingPathCalls, 1);
      expect(states, hasLength(3));
    });
  });

  group('with the real garbage collector', () {
    test('an object that was collected is never reported, one that is retained is', () async {
      final f = fixture(gc: _ForceGcTrigger());
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
      f.engine.install();
      final retained = _createState();
      void disposeTemporary() => _dispose(_createState());

      disposeTemporary();
      _dispose(retained);
      await f.time.elapse(const Duration(seconds: 5));
      final succeeded = await f.waitForEvent<HeapAnalysisSucceededEvent>();

      final dumped = succeeded.heapAnalysis.dump.objects;
      expect(dumped, hasLength(1), reason: 'the temporary State was collected before the dump');
      expect(dumped.single.identityHash, identityHashCode(retained));
      expect(f.engine.hub.leakHistory.single.reason, '_TestState received State#dispose() callback');
      expect(retained, isNotNull);
    });

    test('when everything was collected nothing is dumped', () async {
      final f = fixture(gc: _ForceGcTrigger());
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
      f.engine.install();
      void disposeTemporary() => _dispose(_createState());

      disposeTemporary();
      disposeTemporary();
      await f.time.elapse(const Duration(seconds: 5));
      // The check waits for a real GC, which time.elapse does not wait for.
      await Future<void>.delayed(const Duration(seconds: 3));
      await f.time.elapse(Duration.zero);

      expect(f.eventsOf<HeapDumpEvent>(), isEmpty);
      expect(f.engine.retainedObjectCount, 0);
      expect(f.engine.hub.leakHistory, isEmpty);
    });
  });

  group('in a test environment', () {
    test('heap dumping is turned off by default, and says why', () async {
      final log = captureLog();
      final f = fixture(overrideTestEnvironment: false);
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
      f.engine.install();
      final state = _createState();

      _dispose(state);
      await f.time.elapse(const Duration(seconds: 5));

      expect(f.fakeGc.calls, 0);
      expect(f.eventsOf<HeapDumpEvent>(), isEmpty);
      expect(f.engine.retainedObjectCount, 1, reason: 'objects are still watched and counted');
      expect(
        log.lines,
        contains(
          'LeakSentry is currently disabled: running in a test environment (FLUTTER_TEST), so heap dumping is turned off.',
        ),
      );
      expect(state, isNotNull);
    });
  });

  group('visibility', () {
    test('is tracked from install, and the trigger hears about it', () async {
      final f = fixture();
      expect(f.visibility.isStarted, isFalse);

      f.engine.install();

      expect(f.visibility.isStarted, isTrue);
      f.engine.dispose();
      expect(f.visibility.isStarted, isFalse);
    });
  });

  group('the config', () {
    test('turning dumping back on checks right away', () async {
      final f = fixture();
      f.engine.config = const LeakSentryConfig(dumpHeap: false, retainedVisibleThreshold: 1);
      f.engine.install();
      final state = _createState();
      _dispose(state);
      await f.time.elapse(const Duration(seconds: 10));
      expect(f.eventsOf<HeapDumpEvent>(), isEmpty);

      f.engine.config = f.engine.config.copyWith(dumpHeap: true);
      await f.settle();

      expect(f.eventsOf<HeapDumpEvent>(), hasLength(1));
      expect(state, isNotNull);
    });

    test('the Settings switch checks right away too', () async {
      final f = fixture();
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
      f.engine.dumpEnabledInAboutScreen = false;
      f.engine.install();
      final state = _createState();
      _dispose(state);
      await f.time.elapse(const Duration(seconds: 10));
      expect(f.eventsOf<HeapDumpEvent>(), isEmpty);
      expect(f.notifier.calls.last, 'retained(1, "Heap dumping disabled from the LeakSentry Settings screen")');

      f.engine.dumpEnabledInAboutScreen = true;
      await f.settle();

      expect(f.eventsOf<HeapDumpEvent>(), hasLength(1));
      expect(state, isNotNull);
    });

    test('a custom heap dumper is used instead of the default', () async {
      final f = fixture();
      final dumper = _CountingDumper();
      f.engine.config = LeakSentryConfig(retainedVisibleThreshold: 1, heapDumper: dumper);
      f.engine.install();
      final state = _createState();

      _dispose(state);
      await f.time.elapse(const Duration(seconds: 5));

      expect(dumper.calls, 1);
      expect(state, isNotNull);
    });
  });

  group('dumpHeap', () {
    test('does nothing before install', () async {
      final f = fixture();

      await f.engine.dumpHeap(forceDump: true);

      expect(f.fakeGc.calls, 0);
      expect(f.events, isEmpty);
    });

    test('without force and with nothing retained, it only says so', () async {
      final f = fixture();
      f.engine.install();

      await f.engine.dumpHeap();

      expect(f.eventsOf<HeapDumpEvent>(), isEmpty);
      expect(f.notifier.calls, contains('noRetainedOnRequest'));
    });

    test('with something retained it dumps and analyzes, whatever the threshold', () async {
      final f = fixture();
      f.engine.install();
      final state = _createState();
      _dispose(state);
      await f.time.elapse(const Duration(seconds: 5));
      expect(f.eventsOf<HeapDumpEvent>(), isEmpty);

      await f.engine.dumpHeap();
      await f.settle();

      expect(f.eventsOf<HeapDumpEvent>().single.reason, 'user request');
      expect(f.engine.hub.leakHistory, hasLength(1));
      expect(state, isNotNull);
    });
  });

  group('runGc', () {
    test('forces a GC through the trigger, without being installed, and says whether it was confirmed', () async {
      final f = fixture();

      expect(await f.engine.runGc(), isTrue);
      f.fakeGc.confirmed = false;
      expect(await f.engine.runGc(), isFalse);

      expect(f.fakeGc.calls, 2);
    });
  });


  group('on the web', () {
    test('install only counts retained objects: nothing is ever dumped', () async {
      final log = captureLog();
      final f = fixture(web: true);
      f.engine.install();
      final state = _createState();

      _dispose(state);
      await f.time.elapse(const Duration(seconds: 30));

      expect(f.engine.isInstalled, isTrue);
      expect(f.engine.retainedObjectCount, 1);
      expect(f.fakeGc.calls, 0);
      expect(f.eventsOf<HeapDumpEvent>(), isEmpty);
      expect(f.visibility.isStarted, isFalse);
      expect(log.lines, contains(startsWith('LeakSentry cannot force a garbage collection or look up retaining paths on the web')));
      expect(state, isNotNull);
    });

    test('installing from the widget does the same', () async {
      final f = fixture(web: true);

      expect(f.engine.installIfNeeded(), isTrue);
      final state = _createState();
      _dispose(state);
      await f.time.elapse(const Duration(seconds: 30));

      expect(f.engine.retainedObjectCount, 1);
      expect(f.fakeGc.calls, 0);
      expect(state, isNotNull);
    });

    test('a requested dump does nothing, and forcing a GC says it was not confirmed', () async {
      final f = fixture(web: true);
      f.engine.install();

      await f.engine.dumpHeap(forceDump: true);

      expect(f.events, isEmpty);
    });
  });

  group('dumpHeap and the analysis', () {
    test('completes once the leaks of that dump are in the hub, not before', () async {
      final f = fixture();
      f.engine.install();
      final state = _createState();
      _dispose(state);
      await f.time.elapse(const Duration(seconds: 5));
      final gate = Completer<void>();
      f.vm.retainingPathGate = () => gate.future;

      var completed = false;
      final dumping = f.engine.dumpHeap().then((_) => completed = true);
      await pumpEventQueue();
      expect(f.eventsOf<HeapDumpEvent>(), hasLength(1), reason: 'the heap was dumped and the analysis is under way');
      expect(completed, isFalse, reason: 'the analysis is waiting for the VM');
      expect(f.engine.hub.leakHistory, isEmpty);

      gate.complete();
      await dumping;

      expect(f.engine.hub.leakHistory, hasLength(1));
      expect(() => f.engine.hub.expectNoLeaks(), throwsStateError, reason: 'what a test relies on');
      expect(state, isNotNull);
    });

    test('completes at once when nothing was dumped', () async {
      final f = fixture();
      f.engine.install();

      await f.engine.dumpHeap();

      expect(f.eventsOf<HeapDumpEvent>(), isEmpty);
    });

    test('completes at once when the dump failed', () async {
      final f = fixture();
      final failing = _FailingDumper();
      f.engine.config = LeakSentryConfig(heapDumper: failing);
      f.engine.install();

      await f.engine.dumpHeap(forceDump: true);

      expect(f.eventsOf<HeapDumpFailedEvent>(), hasLength(1));
    });

    test('does not wait for an analysis that something else runs', () async {
      final f = fixture(analysisWait: const Duration(seconds: 30));
      f.engine.config = LeakSentryConfig(eventListeners: [_RecordingListener([])]);
      f.engine.install();

      await f.engine.dumpHeap(forceDump: true).timeout(const Duration(seconds: 2));

      expect(f.eventsOf<HeapDumpEvent>(), hasLength(1));
    });

    test('stops waiting for an analysis that takes too long', () async {
      final f = fixture(analysisWait: const Duration(milliseconds: 50));
      f.engine.install();
      f.vm.retainingPathGate = () => Completer<void>().future;
      final state = _createState();
      _dispose(state);
      await f.time.elapse(const Duration(seconds: 5));

      await f.engine.dumpHeap().timeout(const Duration(seconds: 5));

      expect(f.engine.hub.leakHistory, isEmpty, reason: 'the analysis is still running');
      expect(state, isNotNull);
    });

    test('is released when the engine is disposed meanwhile', () async {
      final f = fixture();
      f.engine.install();
      f.vm.retainingPathGate = () => Completer<void>().future;
      final state = _createState();
      _dispose(state);
      await f.time.elapse(const Duration(seconds: 5));
      final dumping = f.engine.dumpHeap();
      await pumpEventQueue();

      f.engine.dispose();

      await dumping.timeout(const Duration(seconds: 5));
      expect(state, isNotNull);
    });
  });

  group('slow event listeners', () {
    test('one that takes too long is no longer waited for, and the others still hear the event', () async {
      final log = captureLog();
      final f = fixture(listenerWait: const Duration(milliseconds: 30));
      final received = <LeakSentryEvent>[];
      f.engine.config = LeakSentryConfig(
        retainedVisibleThreshold: 1,
        eventListeners: [_HoldingListener(Completer<void>().future), _RecordingListener(received)],
      );
      f.engine.install();
      final state = _createState();

      _dispose(state);
      await f.time.elapse(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await f.settle();

      expect(received.map((event) => event.runtimeType), [DumpingHeapEvent, HeapDumpEvent]);
      expect(log.lines.where((line) => line.startsWith('An event listener took more than 30 ms on DumpingHeapEvent')), hasLength(1));
      expect(state, isNotNull);
    });
  });

  group('event listeners', () {
    test('the defaults log and analyze', () {
      final f = fixture();

      expect(f.engine.defaultEventListeners, hasLength(2));
      expect(() => f.engine.defaultEventListeners.add(_RecordingListener([])), throwsUnsupportedError);
    });

    test('replacing them replaces the analysis too', () async {
      final f = fixture();
      final received = <LeakSentryEvent>[];
      f.engine.config = LeakSentryConfig(retainedVisibleThreshold: 1, eventListeners: [_RecordingListener(received)]);
      f.engine.install();
      final state = _createState();

      _dispose(state);
      await f.time.elapse(const Duration(seconds: 5));

      expect(received.map((event) => event.runtimeType), [DumpingHeapEvent, HeapDumpEvent]);
      expect(f.engine.hub.leakHistory, isEmpty, reason: 'nothing analyzed the dump');
      expect(state, isNotNull);
    });

    test('adding one keeps the defaults', () async {
      final f = fixture();
      final received = <LeakSentryEvent>[];
      f.engine.config = LeakSentryConfig(
        retainedVisibleThreshold: 1,
        eventListeners: [...f.engine.defaultEventListeners, _RecordingListener(received)],
      );
      f.engine.install();
      final state = _createState();

      _dispose(state);
      await f.time.elapse(const Duration(seconds: 5));

      expect(received.whereType<HeapAnalysisSucceededEvent>(), hasLength(1));
      expect(f.engine.hub.leakHistory, hasLength(1));
      expect(state, isNotNull);
    });

    test('a listener that throws is logged and the others still hear the event', () async {
      final log = captureLog();
      final f = fixture();
      final received = <LeakSentryEvent>[];
      f.engine.config = LeakSentryConfig(
        retainedVisibleThreshold: 1,
        eventListeners: [_ThrowingListener(), _RecordingListener(received)],
      );
      f.engine.install();
      final state = _createState();

      _dispose(state);
      await f.time.elapse(const Duration(seconds: 5));

      expect(received.map((event) => event.runtimeType), [DumpingHeapEvent, HeapDumpEvent]);
      expect(log.lines.where((line) => line == 'An event listener failed on DumpingHeapEvent'), hasLength(1));
      expect(state, isNotNull);
    });

    test('a listener can hold up the chain, and the stream carries every event whatever the listeners are', () async {
      final f = fixture();
      final release = Completer<void>();
      f.engine.config = LeakSentryConfig(
        retainedVisibleThreshold: 1,
        eventListeners: [_HoldingListener(release.future)],
      );
      f.engine.install();
      final state = _createState();

      _dispose(state);
      await f.time.elapse(const Duration(seconds: 5));
      expect(f.events.map((event) => event.runtimeType), [DumpingHeapEvent]);

      release.complete();
      await f.settle();
      expect(f.events.map((event) => event.runtimeType), [DumpingHeapEvent, HeapDumpEvent]);
      expect(state, isNotNull);
    });
  });

  group('resources', () {
    test('a resource that was never closed is reported through the same hub', () async {
      final f = fixture();

      final token = f.engine.resourceTracker.trackResource(Object(), label: 'a controller');
      f.finalizer.simulateCollected(token);

      expect(f.engine.hub.leakHistory.single.confidence, LeakConfidence.resourceNeverClosed);
      expect(f.engine.hub.expectNoLeaks, throwsStateError);
    });

    test('works without installing anything', () {
      final f = fixture();
      expect(f.engine.isInstalled, isFalse);

      final token = f.engine.resourceTracker.trackResource(Object());
      token.markClosed();
      f.finalizer.simulateCollected(token);

      expect(f.engine.hub.leakHistory, isEmpty);
    });
  });

  test('stats are the ones the router fills in, and the checks add to them', () async {
    final f = fixture();
    f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
    f.engine.install();
    final state = _createState();

    _dispose(state);
    await f.time.elapse(const Duration(seconds: 5));

    expect(f.engine.stats, same(f.router.stats));
    expect(f.engine.stats.creationEvents, greaterThanOrEqualTo(1));
    expect(f.engine.stats.disposalEvents, 1);
    expect(f.engine.stats.retainedChecks, 1);
    expect(f.engine.stats.forcedGcs, 1);
    expect(f.engine.stats.heapDumps, 1);
    expect(f.engine.stats.analyses, 1);
    expect(state, isNotNull);
  });

  test('kFlutterMemoryAllocationsEnabled holds in tests, which the automatic watchers rely on', () {
    expect(kFlutterMemoryAllocationsEnabled, isTrue);
  });
}

class _ReasonReporter implements DeletableObjectReporter {
  _ReasonReporter(this._reasons);

  final List<String> _reasons;

  @override
  TrackedObjectReachability expectDeletionFor(Object target, String reason) {
    _reasons.add(reason);
    return const UntrackedObjectReachability();
  }
}

class _RecordingListener implements LeakSentryEventListener {
  _RecordingListener(this._events);

  final List<LeakSentryEvent> _events;

  @override
  void onEvent(LeakSentryEvent event) => _events.add(event);
}

class _ThrowingListener implements LeakSentryEventListener {
  @override
  void onEvent(LeakSentryEvent event) => throw StateError('listener failed');
}

class _HoldingListener implements LeakSentryEventListener {
  _HoldingListener(this._gate);

  final Future<void> _gate;

  @override
  Future<void> onEvent(LeakSentryEvent event) => event is DumpingHeapEvent ? _gate : Future<void>.value();
}

class _CountingDumper implements HeapDumper {
  int calls = 0;

  @override
  Future<RetainedObjectsDump> dumpHeap() async {
    calls++;
    return const RetainedObjectsDump(objects: [], dumpUptime: Duration.zero);
  }
}

class _FailingDumper implements HeapDumper {
  @override
  Future<RetainedObjectsDump> dumpHeap() async => throw StateError('no space');
}
