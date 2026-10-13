import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/heap_dump_control.dart';
import 'package:leak_sentry/core/heap_dump_policy.dart';
import 'package:leak_sentry/core/heap_dump_trigger.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';
import 'package:leak_sentry/core/retain_instance_event.dart';
import 'package:leak_sentry/models/leak_sentry_stats.dart';

import 'fakes/fake_gc_trigger.dart';
import 'fakes/fake_heap_dumper.dart';
import 'fakes/fake_retained_object_tracker.dart';
import 'fakes/fake_time.dart';
import 'fakes/recording_notifier.dart';
import 'helpers/capture_log.dart';

const _retainedDelay = Duration(seconds: 5);

/// A [HeapDumpTrigger] wired to fakes, the way the engine wires the real one.
class _Harness {
  _Harness({Duration maxGcWait = HeapDumpPolicy.maxGcWait, Duration maxDumpWait = HeapDumpPolicy.maxDumpWait}) {
    dumper = FakeHeapDumper(time.clock);
    control = HeapDumpControl(
      isInstalled: () => installed,
      config: () => config,
      dumpEnabledInAboutScreen: () => dumpEnabledInAboutScreen,
      testEnvironment: () => testEnvironment,
      scheduleRetainedObjectCheck: () => trigger.scheduleRetainedObjectCheck(),
    );
    var nextId = 0;
    trigger = HeapDumpTrigger(
      retainedObjectTracker: tracker,
      gcTrigger: gc,
      configProvider: () => config,
      heapDumperProvider: () => dumper,
      heapDumpControl: control,
      clock: time.clock,
      scheduler: time,
      retainedDelayProvider: () => _retainedDelay,
      sendEvent: (event) async {
        events.add(event);
        await onEvent?.call(event);
      },
      onRetainInstanceListener: retainEvents.add,
      notifier: notifier,
      stats: stats,
      uniqueIdFactory: () => 'id${++nextId}',
      maxGcWait: maxGcWait,
      maxDumpWait: maxDumpWait,
    );
  }

  final time = FakeTime();
  final tracker = FakeRetainedObjectTracker();
  final gc = FakeGcTrigger();
  final notifier = RecordingNotifier();
  final stats = LeakSentryStats();
  final events = <LeakSentryEvent>[];
  final retainEvents = <RetainInstanceEvent>[];
  late final FakeHeapDumper dumper;
  late final HeapDumpControl control;
  late final HeapDumpTrigger trigger;

  /// Awaited after each event is recorded, so a test can hold the chain up.
  Future<void> Function(LeakSentryEvent event)? onEvent;

  LeakSentryConfig config = const LeakSentryConfig();
  bool installed = true;
  bool dumpEnabledInAboutScreen = true;
  String? testEnvironment;

  /// An object reaching the end of its retained delay, which is what tells the
  /// trigger to look.
  void retain([int count = 1]) {
    tracker.retained += count;
    tracker.newestRetained = time.now;
    trigger.scheduleRetainedObjectCheck();
  }

  Iterable<T> eventsOf<T extends LeakSentryEvent>() => events.whereType<T>();
}

void main() {
  late _Harness h;
  late CapturingLogger log;

  setUp(() {
    log = captureLog();
    h = _Harness();
  });

  tearDown(() => h.trigger.dispose());

  group('a check', () {
    test('forces a GC, then counts again, before deciding anything', () async {
      // Five objects are retained, enough to dump, but three of them were only
      // waiting to be collected.
      h.gc.onRunGc = () async => h.tracker.retained = 2;
      h.retain(5);

      await h.time.elapse(Duration.zero);

      expect(h.gc.calls, 1);
      expect(h.dumper.calls, 0);
      expect(log.lines, contains('Found 2 objects retained, not dumping heap yet (app is visible & < 5 threshold)'));
    });

    test('says when every retained object has been collected, once something was shown', () async {
      h.retain(1);
      await h.time.elapse(Duration.zero);
      expect(log.lines, isNot(contains('All retained objects have been garbage collected')));

      await h.time.elapse(const Duration(seconds: 1));
      h.gc.onRunGc = () async => h.tracker.retained = 0;
      h.retain(1);
      await h.time.elapse(const Duration(seconds: 1));

      expect(log.lines, contains('All retained objects have been garbage collected'));
      expect(h.retainEvents.last, isA<NoMoreObjectsEvent>());
    });

    test('says nothing when the first GC already collected everything', () async {
      h.gc.onRunGc = () async => h.tracker.retained = 0;
      h.retain(3);

      await h.time.elapse(Duration.zero);

      expect(h.dumper.calls, 0);
      expect(h.retainEvents, isEmpty, reason: 'nothing was ever shown, so there is nothing to take back');
    });

    test('does not run a GC when nothing is retained', () async {
      h.trigger.scheduleRetainedObjectCheck();

      await h.time.elapse(Duration.zero);

      expect(h.gc.calls, 0);
      expect(h.retainEvents, isEmpty, reason: 'the count never changed from zero');
      expect(h.notifier.calls, isEmpty);
    });

    test('only one can be pending: later requests are ignored whatever their delay', () async {
      h.trigger.scheduleRetainedObjectCheck(delay: const Duration(seconds: 10));
      h.trigger.scheduleRetainedObjectCheck();
      h.trigger.scheduleRetainedObjectCheck(delay: const Duration(seconds: 1));

      expect(h.time.pendingDelays, [const Duration(seconds: 10)]);
    });

    test('a request made while the check runs schedules the next one', () async {
      h.retain(1);
      h.gc.onRunGc = () async => h.trigger.scheduleRetainedObjectCheck(delay: const Duration(seconds: 7));

      await h.time.elapse(Duration.zero);

      // The check's own 2 s recheck was ignored: one was already pending.
      expect(h.time.pendingDelays, [const Duration(seconds: 7)]);
    });

    test('is retried in 5 s when it fails', () async {
      h.retain(1);
      h.gc.error = StateError('gc failed');

      await h.time.elapse(Duration.zero);

      expect(h.time.pendingDelays, [const Duration(seconds: 5)]);
      expect(log.lines.any((line) => line.startsWith('Checking retained objects failed')), isTrue);

      h.gc.error = null;
      await h.time.elapse(const Duration(seconds: 5));
      expect(h.gc.calls, 2);
    });

    test('counts itself in the stats', () async {
      h.retain(1);
      await h.time.elapse(Duration.zero);

      expect(h.stats.retainedChecks, 1);
      expect(h.stats.forcedGcs, 1);
    });

    test('an unconfirmed GC is counted as a failure but does not stop the check', () async {
      h.gc.confirmed = false;
      h.retain(1);

      await h.time.elapse(Duration.zero);

      expect(h.stats.forcedGcFailures, 1);
      expect(h.stats.forcedGcs, 0);
      expect(h.retainEvents.single, isA<BelowThresholdEvent>());
    });
  });

  group('while the app is visible', () {
    test('below the threshold it announces the count and rechecks every 2 s', () async {
      h.retain(1);

      await h.time.elapse(Duration.zero);

      expect(h.dumper.calls, 0);
      expect(h.retainEvents.single, isA<BelowThresholdEvent>().having((e) => e.retainedCount, 'retainedCount', 1));
      expect(h.notifier.calls, ['retained(1, "App visible, waiting until 5 retained objects")']);
      expect(h.notifier.reasons.single, isA<BelowThresholdEvent>().having((e) => e.retainedCount, 'retainedCount', 1));
      expect(h.time.pendingDelays, [const Duration(seconds: 2)]);
      expect(log.lines, contains('Found 1 object retained, not dumping heap yet (app is visible & < 5 threshold)'));
    });

    test('says "objects" for several, and reports a count only when it changes', () async {
      h.retain(2);
      await h.time.elapse(Duration.zero);
      await h.time.elapse(const Duration(seconds: 2));
      await h.time.elapse(const Duration(seconds: 2));

      expect(
        log.lines.where((line) => line.startsWith('Found')),
        ['Found 2 objects retained, not dumping heap yet (app is visible & < 5 threshold)'],
      );
      expect(h.retainEvents.whereType<BelowThresholdEvent>(), hasLength(1));
      // The notice is refreshed on every recheck, though the count is announced once.
      expect(h.notifier.calls, hasLength(3));
    });

    test('a changed count is announced again', () async {
      h.retain(1);
      await h.time.elapse(Duration.zero);
      h.retain(1);
      await h.time.elapse(const Duration(seconds: 2));

      expect(h.retainEvents.whereType<BelowThresholdEvent>().map((e) => e.retainedCount), [1, 2]);
    });

    test('at the threshold it dumps the heap', () async {
      h.retain(5);

      await h.time.elapse(Duration.zero);

      expect(h.dumper.calls, 1);
      expect(log.lines, contains('Found 5 objects retained, dumping heap now (app is visible & >=5 threshold)'));
      expect(h.eventsOf<HeapDumpEvent>().single.reason, '5 retained objects, app is visible');
    });

    test('the threshold comes from the config', () async {
      h.config = const LeakSentryConfig(retainedVisibleThreshold: 2);
      h.retain(2);

      await h.time.elapse(Duration.zero);

      expect(h.dumper.calls, 1);
    });

    test('dumping dismisses the retained count notice', () async {
      h.retain(1);
      await h.time.elapse(Duration.zero);
      h.retain(4);
      await h.time.elapse(const Duration(seconds: 2));

      expect(h.notifier.calls.last, 'dismissRetained');
    });
  });

  group('when the app is invisible', () {
    test('becoming invisible schedules a check after the retained delay', () async {
      h.trigger.onApplicationVisibilityChanged(false);

      expect(h.time.pendingDelays, [_retainedDelay]);
    });

    test('becoming visible schedules nothing', () async {
      h.trigger.onApplicationVisibilityChanged(true);

      expect(h.time.pendingCount, 0);
    });

    test('a single retained object is dumped once the app has been invisible for the retained delay', () async {
      h.trigger.onApplicationVisibilityChanged(false);
      h.retain(1); // its own check is ignored: the one for the visibility change is already pending

      await h.time.elapse(const Duration(seconds: 4, milliseconds: 999));
      expect(h.dumper.calls, 0, reason: 'objects destroyed on back press still have time to be watched');

      await h.time.elapse(const Duration(milliseconds: 1));
      expect(h.dumper.calls, 1);
      expect(h.eventsOf<HeapDumpEvent>().single.reason, '1 retained objects, app is not visible');
    });

    test('a check already waiting to recheck keeps its own pace, and dumps at the first one after the delay', () async {
      h.retain(1);
      await h.time.elapse(Duration.zero); // schedules a recheck for 2 s
      h.trigger.onApplicationVisibilityChanged(false); // its own check is ignored

      await h.time.elapse(const Duration(seconds: 5));
      expect(h.dumper.calls, 0, reason: 'the checks at 2 s and 4 s still found it just became invisible');

      await h.time.elapse(const Duration(seconds: 1));
      expect(h.dumper.calls, 1);
    });

    test('while it just became invisible it says when it will dump', () async {
      h.retain(1);
      h.trigger.onApplicationVisibilityChanged(false);
      await h.time.elapse(Duration.zero);

      expect(log.lines, contains('Found 1 object retained, dumping heap in 5000 ms (app just became invisible)'));
    });

    test('long after it became invisible it dumps without waiting', () async {
      h.trigger.onApplicationVisibilityChanged(false);
      await h.time.elapse(_retainedDelay);

      h.retain(1);
      await h.time.elapse(Duration.zero);

      expect(log.lines, contains('Found 1 object retained, dumping heap now (app is invisible)'));
      expect(h.dumper.calls, 1);
    });

    test('coming back before the delay ends goes back to waiting for the threshold', () async {
      h.retain(1);
      await h.time.elapse(Duration.zero);
      h.trigger.onApplicationVisibilityChanged(false);
      await h.time.elapse(const Duration(seconds: 2));
      h.trigger.onApplicationVisibilityChanged(true);

      await h.time.elapse(const Duration(seconds: 10));

      expect(h.dumper.calls, 0);
    });
  });

  group('dumping the heap', () {
    test('announces the dump, then the dump, with a new id for the second', () async {
      h.retain(5);

      await h.time.elapse(Duration.zero);

      expect(h.events, [isA<DumpingHeapEvent>(), isA<HeapDumpEvent>()]);
      expect(h.events[0].uniqueId, 'id1');
      expect(h.events[1].uniqueId, 'id2', reason: 'the id is replaced right before HeapDump is sent');
      expect(h.stats.heapDumps, 1);
    });

    test('forgets everything watched before the dump, so it is never reported twice', () async {
      h.retain(5);
      await h.time.elapse(const Duration(seconds: 3));
      final dumpUptime = h.dumper.dumps.single.dumpUptime;

      expect(h.tracker.clearedBefore, [dumpUptime]);
    });

    test('forgets nothing when the dump fails', () async {
      h.dumper.error = StateError('no space');
      h.retain(5);

      await h.time.elapse(Duration.zero);

      expect(h.tracker.clearedBefore, isEmpty);
      expect(h.tracker.retained, 5);
    });

    test('a failed dump is announced, retried in 5 s, and the retry reuses the event id', () async {
      h.dumper.error = StateError('no space');
      h.retain(5);

      await h.time.elapse(Duration.zero);

      final failed = h.eventsOf<HeapDumpFailedEvent>().single;
      expect(failed.willRetryLater, isTrue);
      expect(failed.exception, isA<StateError>());
      expect(failed.uniqueId, 'id1');
      expect(h.time.pendingDelays, [const Duration(seconds: 5)]);
      expect(h.notifier.calls.last, 'retained(5, "Failed to dump heap")');
      expect(h.notifier.reasons.last, isNull, reason: 'a failed dump is not waiting for anything');
      expect(h.stats.heapDumpFailures, 1);

      h.dumper.error = null;
      await h.time.elapse(const Duration(seconds: 5));

      expect(h.dumper.calls, 2);
      final dumping = h.eventsOf<DumpingHeapEvent>().toList();
      expect(dumping.map((e) => e.uniqueId), ['id1', 'id1']);
      expect(h.eventsOf<HeapDumpEvent>().single.uniqueId, 'id2');
    });

    test('waits for the listeners of DumpingHeap before it dumps', () async {
      final release = Completer<void>();
      h.onEvent = (event) => event is DumpingHeapEvent ? release.future : Future<void>.value();
      h.retain(5);

      await h.time.elapse(Duration.zero);
      expect(h.events, [isA<DumpingHeapEvent>()]);
      expect(h.dumper.calls, 0);

      release.complete();
      await pumpEventQueue();
      expect(h.dumper.calls, 1);
    });
  });

  group('between dumps', () {
    test('the first dump is never held back, even early in the process', () async {
      // The clock reads close to zero here, as a process-relative clock does.
      h.retain(5);

      await h.time.elapse(Duration.zero);

      expect(h.dumper.calls, 1);
      expect(h.retainEvents.whereType<DumpHappenedRecentlyEvent>(), isEmpty);
    });

    test('a second dump less than 60 s later waits for the rest of the minute', () async {
      h.retain(5);
      await h.time.elapse(Duration.zero);
      await h.time.elapse(const Duration(seconds: 20));

      h.retain(5);
      await h.time.elapse(Duration.zero);

      expect(h.dumper.calls, 1);
      expect(h.retainEvents.whereType<DumpHappenedRecentlyEvent>(), hasLength(1));
      expect(h.notifier.calls.last, 'retained(5, "Last heap dump was less than a minute ago")');
      expect(h.notifier.reasons.last, isA<DumpHappenedRecentlyEvent>());
      expect(h.time.pendingDelays, [const Duration(seconds: 40)]);

      await h.time.elapse(const Duration(seconds: 40));
      expect(h.dumper.calls, 2);
    });

    test('a count below the threshold is not blocked by the spacing, it just waits', () async {
      h.retain(5);
      await h.time.elapse(Duration.zero);

      h.retain(1);
      await h.time.elapse(Duration.zero);

      expect(h.retainEvents.whereType<DumpHappenedRecentlyEvent>(), isEmpty);
      expect(h.retainEvents.last, isA<BelowThresholdEvent>());
    });
  });

  group('when the developer asks for a dump', () {
    test('with nothing retained after the GC, and no force, it dumps nothing and says so', () async {
      await h.trigger.onDumpHeapReceived(forceDump: false);

      expect(h.gc.calls, 1);
      expect(h.dumper.calls, 0);
      expect(h.notifier.calls, ['dismissNoRetainedOnRequest', 'noRetainedOnRequest']);
      expect(log.lines, contains('Ignoring user request to dump heap: no retained objects remaining after GC'));
    });

    test('the "nothing retained" notice goes away after 30 s', () async {
      await h.trigger.onDumpHeapReceived(forceDump: false);
      h.notifier.calls.clear();

      await h.time.elapse(const Duration(seconds: 29));
      expect(h.notifier.calls, isEmpty);
      await h.time.elapse(const Duration(seconds: 1));
      expect(h.notifier.calls, ['dismissNoRetainedOnRequest']);
    });

    test('a new request takes the "nothing retained" notice down first', () async {
      await h.trigger.onDumpHeapReceived(forceDump: false);
      h.notifier.calls.clear();

      await h.trigger.onDumpHeapReceived(forceDump: false);

      expect(h.notifier.calls.first, 'dismissNoRetainedOnRequest');
      expect(h.time.pendingCount, 1, reason: 'only the new notice has a dismissal pending');
    });

    test('with something retained it dumps whatever the threshold', () async {
      h.tracker.retained = 1;

      await h.trigger.onDumpHeapReceived(forceDump: false);

      expect(h.gc.calls, 1);
      expect(h.dumper.calls, 1);
      expect(h.eventsOf<HeapDumpEvent>().single.reason, 'user request');
      expect(log.lines, contains('Dumping the heap because user requested it'));
    });

    test('a dump takes the retained count down: what it counted is being dumped', () async {
      h.retain(2);
      await h.time.elapse(Duration.zero);
      expect(h.notifier.calls.last, startsWith('retained(2'));
      h.notifier.calls.clear();

      await h.trigger.onDumpHeapReceived(forceDump: false);

      expect(h.notifier.calls, ['dismissNoRetainedOnRequest', 'dismissRetained']);
      expect(h.dumper.calls, 1);
    });

    test('with nothing to dump it leaves the retained count alone', () async {
      await h.trigger.onDumpHeapReceived(forceDump: false);

      expect(h.notifier.calls, isNot(contains('dismissRetained')));
    });

    test('with force it dumps even when nothing is retained', () async {
      await h.trigger.onDumpHeapReceived(forceDump: true);

      expect(h.dumper.calls, 1);
    });

    test('it ignores the spacing between dumps and the dump controls', () async {
      h.retain(5);
      await h.time.elapse(Duration.zero);
      h.config = const LeakSentryConfig(dumpHeap: false);
      h.tracker.retained = 1;

      await h.trigger.onDumpHeapReceived(forceDump: false);

      expect(h.dumper.calls, 2);
    });

    test('a failed requested dump is not retried', () async {
      h.dumper.error = StateError('no space');

      await h.trigger.onDumpHeapReceived(forceDump: true);

      final failed = h.eventsOf<HeapDumpFailedEvent>().single;
      expect(failed.willRetryLater, isFalse);
      expect(h.time.pendingCount, 0);
    });

    test('waits for a check that is in progress', () async {
      final release = Completer<void>();
      h.gc.onRunGc = () => release.future;
      h.retain(1);
      await h.time.elapse(Duration.zero);
      expect(h.gc.calls, 1, reason: 'the check is held up inside its GC');

      var finished = false;
      final request = h.trigger.onDumpHeapReceived(forceDump: true).then((_) => finished = true);
      await pumpEventQueue();
      expect(h.gc.calls, 1, reason: 'the request must not start while the check is running');
      expect(finished, isFalse);

      h.gc.onRunGc = null;
      release.complete();
      await request;
      expect(h.gc.calls, 2);
      expect(h.dumper.calls, 1);
    });
  });

  group('when something forbids dumping', () {
    test('in silence: it logs why and does nothing else', () async {
      h.config = const LeakSentryConfig(dumpHeap: false);
      h.retain(10);

      await h.time.elapse(Duration.zero);

      expect(h.gc.calls, 0);
      expect(h.dumper.calls, 0);
      expect(h.notifier.calls, isEmpty);
      expect(log.lines, contains('LeakSentry is currently disabled: LeakSentryConfig.dumpHeap is set to false.'));
      expect(h.time.pendingCount, 0);
    });

    test('running tests is a silent no too', () async {
      h.testEnvironment = 'FLUTTER_TEST';
      h.retain(10);

      await h.time.elapse(Duration.zero);

      expect(h.dumper.calls, 0);
      expect(h.notifier.calls, isEmpty);
    });

    test('not installed is a silent no too', () async {
      h.installed = false;
      h.retain(10);

      await h.time.elapse(Duration.zero);

      expect(h.dumper.calls, 0);
      expect(log.lines, contains('LeakSentry is currently disabled: LeakSentry is not installed..'));
    });

    test('out loud: a count that would dump is announced instead, after a GC', () async {
      h.dumpEnabledInAboutScreen = false;
      h.retain(5);

      await h.time.elapse(Duration.zero);

      expect(h.gc.calls, 1);
      expect(h.dumper.calls, 0);
      expect(
        h.retainEvents.single,
        isA<DumpingDisabledEvent>().having(
          (e) => e.reason,
          'reason',
          'Heap dumping disabled from the LeakSentry Settings screen',
        ),
      );
      expect(h.notifier.calls, ['retained(5, "Heap dumping disabled from the LeakSentry Settings screen")']);
      expect(
        h.notifier.reasons.single,
        isA<DumpingDisabledEvent>().having(
          (e) => e.reason,
          'reason',
          'Heap dumping disabled from the LeakSentry Settings screen',
        ),
      );
      expect(
        log.lines,
        contains(
          'Found 5 objects retained, would dump heap now (app is visible & >=5 threshold) '
          'but heap dumping disabled from the LeakSentry Settings screen',
        ),
      );
    });

    test('out loud: a count below the threshold still waits as usual', () async {
      h.dumpEnabledInAboutScreen = false;
      h.retain(1);

      await h.time.elapse(Duration.zero);

      expect(h.retainEvents.single, isA<BelowThresholdEvent>());
      expect(h.time.pendingDelays, [const Duration(seconds: 2)]);
    });

    test('out loud: when the objects were collected, it says so instead', () async {
      h.dumpEnabledInAboutScreen = false;
      h.retain(1);
      await h.time.elapse(Duration.zero);

      await h.time.elapse(const Duration(seconds: 1));
      h.gc.onRunGc = () async => h.tracker.retained = 0;
      h.retain(1);
      await h.time.elapse(const Duration(seconds: 1));

      expect(h.retainEvents.last, isA<NoMoreObjectsEvent>());
    });

    test('allowing it again checks right away, so objects that piled up are not forgotten', () async {
      h.dumpEnabledInAboutScreen = false;
      h.retain(5);
      await h.time.elapse(Duration.zero);
      expect(h.dumper.calls, 0);

      h.dumpEnabledInAboutScreen = true;
      h.control.iCanHasHeap();
      await h.time.elapse(Duration.zero);

      expect(h.dumper.calls, 1);
    });
  });

  group('the NoMoreObjects notice', () {
    test('appears when the count drops to zero, and dismisses itself after 30 s', () async {
      h.retain(1);
      await h.time.elapse(Duration.zero);
      h.notifier.calls.clear();

      h.tracker.retained = 0;
      await h.time.elapse(const Duration(seconds: 2));
      expect(h.notifier.calls, ['noMoreRetained']);

      await h.time.elapse(const Duration(seconds: 29));
      expect(h.notifier.calls, ['noMoreRetained']);
      await h.time.elapse(const Duration(seconds: 1));
      expect(h.notifier.calls, ['noMoreRetained', 'dismissRetained']);
    });

    test('is not shown again while the count stays at zero', () async {
      h.trigger.scheduleRetainedObjectCheck();
      await h.time.elapse(Duration.zero);
      h.trigger.scheduleRetainedObjectCheck();
      await h.time.elapse(Duration.zero);

      expect(h.notifier.calls, isEmpty);
    });

    test('a retained count shown meanwhile cancels its dismissal', () async {
      h.retain(1);
      await h.time.elapse(Duration.zero);
      h.tracker.retained = 0;
      h.trigger.scheduleRetainedObjectCheck();
      await h.time.elapse(const Duration(seconds: 2));
      h.notifier.calls.clear();

      h.retain(1);
      await h.time.elapse(Duration.zero);
      await h.time.elapse(const Duration(seconds: 60));

      expect(h.notifier.calls, isNot(contains('dismissRetained')));
    });
  });

  group('the forced GC', () {
    test('is skipped when the last one already followed every retained object', () async {
      h.retain(1);
      await h.time.elapse(Duration.zero);
      expect(h.gc.calls, 1);

      await h.time.elapse(const Duration(seconds: 2));
      await h.time.elapse(const Duration(seconds: 2));

      expect(h.gc.calls, 1);
      expect(h.stats.forcedGcsSkipped, 2);
    });

    test('runs again when an object became retained after the last one started', () async {
      h.retain(1);
      await h.time.elapse(Duration.zero);

      await h.time.elapse(const Duration(seconds: 1));
      h.retain(1);
      await h.time.elapse(const Duration(seconds: 1));

      expect(h.gc.calls, 2);
    });

    test('runs again once the last one is old enough that a release may have gone unnoticed', () async {
      h.retain(1);
      await h.time.elapse(Duration.zero);

      await h.time.elapse(const Duration(seconds: 59));
      expect(h.gc.calls, 1);

      await h.time.elapse(const Duration(seconds: 2));
      expect(h.gc.calls, 2);
    });

    test('always runs before a dump, even when the last one was recent', () async {
      h.retain(1);
      await h.time.elapse(Duration.zero);
      expect(h.gc.calls, 1);

      h.trigger.onApplicationVisibilityChanged(false);
      await h.time.elapse(const Duration(seconds: 4));
      expect(h.gc.calls, 1, reason: 'rechecks while it only waits skip the GC');

      await h.time.elapse(const Duration(seconds: 2));
      expect(h.gc.calls, 2, reason: 'the count a dump rests on must be fresh');
      expect(h.dumper.calls, 1);
    });

    test('a retained object that turns out collected by the GC before a dump prevents the dump', () async {
      h.retain(1);
      await h.time.elapse(Duration.zero);

      h.trigger.onApplicationVisibilityChanged(false);
      h.gc.onRunGc = () async => h.tracker.retained = 0;
      await h.time.elapse(const Duration(seconds: 6));

      expect(h.dumper.calls, 0);
      expect(h.retainEvents.last, isA<NoMoreObjectsEvent>());
    });
  });


  group('what a dump forgets and when the minute starts', () {
    test('forgets what was watched before the dump started, not what was watched while it ran', () async {
      h.dumper.onDump = () async => h.time.advance(const Duration(seconds: 3));
      h.retain(5);

      await h.time.elapse(Duration.zero);

      expect(h.tracker.clearedBefore, [Duration.zero], reason: 'the dump started at 0 s; it ended at 3 s');
    });

    test('the minute between dumps counts from the end of the dump', () async {
      h.dumper.onDump = () async => h.time.advance(const Duration(seconds: 10));
      h.retain(5);
      await h.time.elapse(Duration.zero);

      await h.time.elapse(const Duration(seconds: 55));
      h.dumper.onDump = null;
      h.retain(5);
      await h.time.elapse(Duration.zero);

      expect(h.retainEvents.whereType<DumpHappenedRecentlyEvent>(), hasLength(1));
      expect(h.time.pendingDelays, [const Duration(seconds: 5)]);
    });

    test('after a dump a count of zero is not announced as everything having been collected', () async {
      h.retain(5);
      await h.time.elapse(Duration.zero);
      expect(h.dumper.calls, 1);

      h.trigger.scheduleRetainedObjectCheck();
      await h.time.elapse(Duration.zero);

      expect(h.retainEvents.whereType<NoMoreObjectsEvent>(), isEmpty, reason: 'nothing was on display to take back');
      expect(h.notifier.calls.where((call) => call == 'noMoreRetained'), isEmpty);
    });

    test('after a request that found nothing retained, a count of zero is not announced either', () async {
      h.retain(2);
      await h.time.elapse(Duration.zero);
      expect(h.retainEvents.last, isA<BelowThresholdEvent>());
      h.tracker.retained = 0;

      await h.trigger.onDumpHeapReceived(forceDump: false);
      await h.time.elapse(const Duration(seconds: 2)); // the recheck that was waiting runs, and finds nothing

      expect(h.retainEvents.whereType<NoMoreObjectsEvent>(), isEmpty, reason: 'the request already said so');
      expect(h.notifier.calls.where((call) => call == 'noMoreRetained'), isEmpty);
    });
  });

  group('the GC and what it settles', () {
    test('a GC that could not be confirmed still counts as the last one, so it is not repeated on every check', () async {
      h.gc.confirmed = false;
      h.retain(1);

      await h.time.elapse(Duration.zero);
      await h.time.elapse(const Duration(seconds: 6));

      expect(h.gc.calls, 1, reason: 'repeating a failing GC every two seconds would only repeat its cost');
      expect(h.stats.forcedGcFailures, 1);
      expect(h.stats.forcedGcsSkipped, 3);
    });

    test('a count exactly at the threshold gets a fresh GC before it dumps', () async {
      h.retain(4);
      await h.time.elapse(Duration.zero);
      expect(h.gc.calls, 1);

      h.config = const LeakSentryConfig(retainedVisibleThreshold: 4);
      await h.time.elapse(const Duration(seconds: 2));

      expect(h.gc.calls, 2, reason: 'what a dump rests on must be fresh');
      expect(h.dumper.calls, 1);
    });

    test('a retained object released after the GC is noticed once the minute is up, by the next GC', () async {
      h.retain(1);
      await h.time.elapse(Duration.zero);
      h.gc.onRunGc = () async => h.tracker.retained = 0; // the holder let go; only a GC shows it

      await h.time.elapse(const Duration(seconds: 58));
      expect(h.retainEvents.whereType<NoMoreObjectsEvent>(), isEmpty);
      expect(h.gc.calls, 1);

      await h.time.elapse(const Duration(seconds: 4));
      expect(h.gc.calls, 2);
      expect(h.retainEvents.last, isA<NoMoreObjectsEvent>());
    });
  });

  group('a request that fails', () {
    test('does not stop the ones after it', () async {
      h.gc.error = StateError('gc failed');
      await expectLater(h.trigger.onDumpHeapReceived(forceDump: true), throwsStateError);

      h.gc.error = null;
      final dumpId = await h.trigger.onDumpHeapReceived(forceDump: true);

      expect(dumpId, isNotNull);
      expect(h.dumper.calls, 1);
    });

    test('does not stop the checks either', () async {
      h.gc.error = StateError('gc failed');
      await expectLater(h.trigger.onDumpHeapReceived(forceDump: true), throwsStateError);
      h.gc.error = null;
      h.retain(5);

      await h.time.elapse(Duration.zero);

      expect(h.dumper.calls, 1);
    });
  });

  group('the id of a requested dump', () {
    test('is the one the dump event was sent with', () async {
      final dumpId = await h.trigger.onDumpHeapReceived(forceDump: true);

      expect(dumpId, h.eventsOf<HeapDumpEvent>().single.uniqueId);
    });

    test('is null when nothing was dumped because nothing is retained', () async {
      expect(await h.trigger.onDumpHeapReceived(forceDump: false), isNull);
    });

    test('is null when the dump failed', () async {
      h.dumper.error = StateError('no space');

      expect(await h.trigger.onDumpHeapReceived(forceDump: true), isNull);
    });
  });

  group('when a GC or a dump never answers', () {
    test('the check gives up on a GC, retries, and the queue is not stuck', () async {
      final never = Completer<void>();
      final stuck = _Harness(maxGcWait: const Duration(milliseconds: 30));
      addTearDown(stuck.trigger.dispose);
      stuck.gc.onRunGc = () => never.future;
      stuck.retain(1);

      await stuck.time.elapse(Duration.zero);
      expect(stuck.time.pendingCount, 0, reason: 'still waiting for the GC');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await stuck.time.elapse(Duration.zero);

      expect(stuck.time.pendingDelays, [const Duration(seconds: 5)], reason: 'a failed check is retried in 5 s');

      stuck.gc.onRunGc = null;
      final dumpId = await stuck.trigger.onDumpHeapReceived(forceDump: true);
      expect(dumpId, isNotNull, reason: 'a request after the hang runs');
    });

    test('the check gives up on a dump, says it failed, and retries', () async {
      final never = Completer<void>();
      final stuck = _Harness(maxDumpWait: const Duration(milliseconds: 30));
      addTearDown(stuck.trigger.dispose);
      stuck.dumper.onDump = () => never.future;
      stuck.retain(5);

      await stuck.time.elapse(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await stuck.time.elapse(Duration.zero);

      final failed = stuck.eventsOf<HeapDumpFailedEvent>().single;
      expect(failed.exception, isA<TimeoutException>());
      expect(failed.willRetryLater, isTrue);
      expect(stuck.time.pendingDelays, [const Duration(seconds: 5)]);
      expect(stuck.tracker.clearedBefore, isEmpty);
    });
  });

  group('disposing while a check is running', () {
    test('during its GC, the count it finds is not announced afterwards and no recheck is scheduled', () async {
      final gate = Completer<void>();
      h.gc.onRunGc = () => gate.future;
      h.retain(1);
      await h.time.elapse(Duration.zero);

      h.trigger.dispose();
      gate.complete();
      await pumpEventQueue();

      expect(h.retainEvents, isEmpty, reason: 'it would have said one object is retained');
      expect(h.notifier.calls, isEmpty);
      expect(h.time.pendingCount, 0);
    });

    test('during its GC, everything having been collected is not announced afterwards, and no dismissal is scheduled', () async {
      h.retain(2);
      await h.time.elapse(Duration.zero); // something is on display, so a count of zero would be news
      await h.time.elapse(const Duration(seconds: 1));
      h.retain(1); // retained after the last GC began, so the recheck runs another
      final gate = Completer<void>();
      h.gc.onRunGc = () async {
        await gate.future;
        h.tracker.retained = 0;
      };
      await h.time.elapse(const Duration(seconds: 1));
      expect(h.gc.calls, 2, reason: 'the recheck is inside its GC');
      h.retainEvents.clear();
      h.notifier.calls.clear();

      h.trigger.dispose();
      gate.complete();
      await pumpEventQueue();

      expect(h.retainEvents, isEmpty);
      expect(h.notifier.calls, isEmpty);
      expect(h.time.pendingCount, 0, reason: 'no 30 s dismissal on a disposed trigger');
    });

    test('while a listener holds up the DumpingHeap event, the heap is not dumped', () async {
      final gate = Completer<void>();
      h.onEvent = (event) => event is DumpingHeapEvent ? gate.future : Future<void>.value();
      h.retain(5);
      await h.time.elapse(Duration.zero);

      h.trigger.dispose();
      gate.complete();
      await pumpEventQueue();

      expect(h.dumper.calls, 0);
      expect(h.eventsOf<HeapDumpEvent>(), isEmpty);
      expect(h.stats.heapDumps, 0);
    });

    test('during the dump, nothing is announced and nothing is forgotten', () async {
      final gate = Completer<void>();
      h.dumper.onDump = () => gate.future;
      h.retain(5);
      await h.time.elapse(Duration.zero);
      expect(h.dumper.calls, 1);

      h.trigger.dispose();
      gate.complete();
      await pumpEventQueue();

      expect(h.eventsOf<HeapDumpEvent>(), isEmpty);
      expect(h.tracker.clearedBefore, isEmpty);
      expect(h.stats.heapDumps, 0);
    });

    test('a requested dump that is disposed during its GC is not taken, and says so', () async {
      final gate = Completer<void>();
      h.gc.onRunGc = () => gate.future;
      final request = h.trigger.onDumpHeapReceived(forceDump: true);
      await pumpEventQueue();

      h.trigger.dispose();
      gate.complete();

      expect(await request, isNull);
      expect(h.dumper.calls, 0);
      expect(h.events, isEmpty, reason: 'not even the DumpingHeap event');
    });
  });

  group('disposing', () {
    test('cancels the pending check', () async {
      h.trigger.scheduleRetainedObjectCheck(delay: const Duration(seconds: 10));

      h.trigger.dispose();

      expect(h.time.pendingCount, 0);
    });

    test('stops new checks from being scheduled', () async {
      h.trigger.dispose();

      h.retain(5);

      expect(h.time.pendingCount, 0);
    });

    test('cancels notice dismissals', () async {
      h.retain(1);
      await h.time.elapse(Duration.zero);
      h.tracker.retained = 0;
      h.trigger.scheduleRetainedObjectCheck();
      await h.time.elapse(Duration.zero);
      expect(h.time.pendingCount, 1);

      h.trigger.dispose();

      expect(h.time.pendingCount, 0);
    });
  });
}
