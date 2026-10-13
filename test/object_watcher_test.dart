import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/object_watcher/delayed_executor.dart';
import 'package:leak_sentry/object_watcher/deletable_object_reporter.dart';
import 'package:leak_sentry/object_watcher/object_watcher.dart';

import 'fakes/fake_time.dart';
import 'helpers/capture_log.dart';
import 'helpers/force_gc.dart';

class _Thing {}

const _delay = Duration(seconds: 5);

void main() {
  late FakeTime time;
  late SchedulerDelayedExecutor executor;
  late bool enabled;
  late StackTrace? Function(Object) creationStackOf;
  late ObjectWatcher watcher;
  late int retainedNotifications;

  setUp(() {
    time = FakeTime();
    executor = SchedulerDelayedExecutor(scheduler: time, clock: time.clock);
    enabled = true;
    creationStackOf = (_) => null;
    retainedNotifications = 0;
    watcher = ObjectWatcher(
      clock: time.clock,
      checkRetainedExecutor: (task) => executor.executeWithDelay(_delay, task),
      isEnabled: () => enabled,
      creationStackOf: (object) => creationStackOf(object),
    )..addOnObjectRetainedListener(() => retainedNotifications++);
  });

  test('an object is retained when its delay ends, not before', () {
    final thing = _Thing();
    watcher.watch(thing, 'why');

    time.advance(const Duration(milliseconds: 4999));
    expect(watcher.retainedObjectCount, 0);
    expect(watcher.hasRetainedObjects, isFalse);
    expect(watcher.hasWatchedObjects, isTrue);
    expect(retainedNotifications, 0);

    time.advance(const Duration(milliseconds: 1));
    expect(watcher.retainedObjectCount, 1);
    expect(watcher.hasRetainedObjects, isTrue);
    expect(retainedNotifications, 1);
  });

  test('each object waits for its own delay, with one timer for all of them', () {
    final things = List.generate(3, (_) => _Thing());
    for (final thing in things) {
      watcher.watch(thing, 'why');
      expect(time.pendingCount, 1);
      time.advance(const Duration(seconds: 1));
    }

    // Watched at 0 s, 1 s and 2 s; now it is 3 s.
    expect(watcher.retainedObjectCount, 0);
    time.advance(const Duration(seconds: 2));
    expect(watcher.retainedObjectCount, 1, reason: 'the first object, watched at 0 s, is due at 5 s');
    time.advance(const Duration(seconds: 1));
    expect(watcher.retainedObjectCount, 2);
    time.advance(const Duration(seconds: 1));
    expect(watcher.retainedObjectCount, 3);
    expect(retainedNotifications, 3);
  });

  test('says why nothing was said when no reason is given', () {
    final log = captureLog(verbose: true);

    watcher.watch(_Thing());

    expect(log.lines.single, 'Watching instance of _Thing (unknown: reason not provided) with key k0');
  });

  test('does nothing while disabled', () {
    enabled = false;

    final reachability = watcher.expectDeletionFor(_Thing(), 'why');

    expect(watcher.trackedObjectCount, 0);
    expect(time.pendingCount, 0);
    expect(reachability, isA<UntrackedObjectReachability>());
    expect(reachability.isRetained, isFalse);
    expect(reachability.isDeletable, isTrue);
  });

  test('records where an object was created, if it is known', () {
    final thing = _Thing();
    final stack = StackTrace.current;
    creationStackOf = (object) => identical(object, thing) ? stack : null;

    watcher.watch(thing, 'why');
    watcher.watch(_Thing(), 'other');

    final references = watcher.tracker.trackedWeakReferences;
    expect(references[0].creationStack, same(stack));
    expect(references[1].creationStack, isNull);
  });

  test('expectDeletionFor tells whether the object ended up retained', () {
    final thing = _Thing();
    final reachability = watcher.expectDeletionFor(thing, 'why');
    expect(reachability.isRetained, isFalse);
    expect(reachability.isStronglyReachable, isTrue);

    time.advance(_delay);

    expect(reachability.isRetained, isTrue);
    expect(reachability.isDeletable, isFalse);
  });

  test('retainedObjects hands back the retained instances', () {
    final retained = _Thing();
    final notYet = _Thing();
    watcher.watch(retained, 'retained');
    time.advance(_delay);
    watcher.watch(notYet, 'not yet');

    expect(watcher.retainedObjects, hasLength(1));
    expect(watcher.retainedObjects.single, same(retained));
  });

  group('with the real garbage collector', () {
    test('an object that is collected during its delay is never retained: nothing waiting for the delay holds it', () async {
      void watchTemporary() => watcher.watch(_Thing(), 'temporary');
      watchTemporary();

      await forceGc();
      time.advance(_delay);

      expect(watcher.retainedObjectCount, 0);
      expect(retainedNotifications, 0);
      expect(watcher.trackedObjectCount, 0);
    });

    test('an object that stays reachable through a GC is retained when its delay ends', () async {
      final kept = _Thing();
      watcher.watch(kept, 'kept');

      await forceGc();
      time.advance(_delay);

      expect(watcher.retainedObjectCount, 1);
      expect(watcher.retainedObjects.single, same(kept));
    });
  });

  group('listeners', () {
    test('can be added and removed, and a listener added twice is called once', () {
      var calls = 0;
      void listener() => calls++;
      watcher.addOnObjectRetainedListener(listener);
      watcher.addOnObjectRetainedListener(listener);
      final thing = _Thing();

      watcher.watch(thing, 'first');
      time.advance(_delay);
      expect(calls, 1);

      watcher.removeOnObjectRetainedListener(listener);
      watcher.watch(thing, 'second');
      time.advance(_delay);
      expect(calls, 1);
    });

    test('may remove themselves while being called', () {
      late void Function() listener;
      var calls = 0;
      listener = () {
        calls++;
        watcher.removeOnObjectRetainedListener(listener);
      };
      watcher.addOnObjectRetainedListener(listener);
      final first = _Thing();
      final second = _Thing();

      watcher.watch(first, 'first');
      watcher.watch(second, 'second');
      time.advance(_delay);

      expect(calls, 1);
      expect(retainedNotifications, 2, reason: 'the listener set up by the test is still there');
    });
  });

  group('clearing', () {
    test('clearObjectsWatchedBefore forgets what was watched at or before a time', () {
      final first = _Thing();
      final second = _Thing();
      watcher.watch(first, 'first');
      time.advance(const Duration(seconds: 1));
      watcher.watch(second, 'second');

      watcher.clearObjectsWatchedBefore(Duration.zero);

      expect(watcher.tracker.trackedWeakReferences.map((reference) => reference.description), ['second']);
    });

    test('a cleared object never becomes retained', () {
      final thing = _Thing();
      watcher.watch(thing, 'why');

      watcher.clearWatchedObjects();
      time.advance(_delay);

      expect(watcher.retainedObjectCount, 0);
      expect(retainedNotifications, 0);
    });

    test('clearObjectsTrackedBefore and clearAllObjectsTracked do the same', () {
      final thing = _Thing();
      watcher.watch(thing, 'first');
      watcher.clearObjectsTrackedBefore(time.now);
      expect(watcher.trackedObjectCount, 0);

      watcher.watch(thing, 'second');
      watcher.clearAllObjectsTracked();
      expect(watcher.trackedObjectCount, 0);
    });
  });
}
