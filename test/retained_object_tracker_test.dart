import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/object_watcher/deletable_object_reporter.dart';
import 'package:leak_sentry/object_watcher/keyed_weak_reference.dart';
import 'package:leak_sentry/object_watcher/retained_object_tracker.dart';

import 'fakes/fake_object_finalizer.dart';
import 'fakes/fake_time.dart';
import 'helpers/capture_log.dart';
import 'helpers/force_gc.dart';

class _Thing {}

void main() {
  late FakeTime time;
  late int retainedNotifications;
  late WeakReferenceRetainedObjectTracker tracker;

  setUp(() {
    time = FakeTime();
    retainedNotifications = 0;
    // The finalizer never fires, so what the tracker says about a collected
    // object comes from its own counts. The real finalizer only prunes the map
    // some time after a collection, which would hide a mistake in them.
    tracker = WeakReferenceRetainedObjectTracker(
      clock: time.clock,
      onObjectRetained: () => retainedNotifications++,
      finalizerFactory: (callback) => FakeObjectFinalizer<String>(callback),
    );
  });

  group('tracking', () {
    test('a tracked object is tracked, not retained, until it is marked', () {
      final thing = _Thing();

      final trigger = tracker.expectDeletionOnTriggerFor(thing, 'why');

      expect(tracker.trackedObjectCount, 1);
      expect(tracker.hasTrackedObjects, isTrue);
      expect(tracker.retainedObjectCount, 0);
      expect(tracker.hasRetainedObjects, isFalse);
      expect(trigger.isStronglyReachable, isTrue);
      expect(trigger.isRetained, isFalse);
      expect(retainedNotifications, 0);
    });

    test('marking a reachable object retained notifies the listener and stamps the time', () {
      final thing = _Thing();
      final trigger = tracker.expectDeletionOnTriggerFor(thing, 'why');
      time.advance(const Duration(seconds: 5));

      trigger.markRetainedIfStronglyReachable();

      expect(tracker.retainedObjectCount, 1);
      expect(tracker.hasRetainedObjects, isTrue);
      expect(trigger.isRetained, isTrue);
      expect(tracker.newestRetainedUptime, const Duration(seconds: 5));
      expect(retainedNotifications, 1);
    });

    test('no object is retained, and nothing is announced, for an unknown or cleared key', () {
      tracker.clearAllObjectsTracked();
      final thing = _Thing();
      final trigger = tracker.expectDeletionOnTriggerFor(thing, 'why');
      tracker.clearAllObjectsTracked();

      trigger.markRetainedIfStronglyReachable();

      expect(tracker.retainedObjectCount, 0);
      expect(retainedNotifications, 0);
      expect(trigger.isStronglyReachable, isFalse);
    });

    test('the newest retained uptime is the latest one, and null when nothing is retained', () {
      expect(tracker.newestRetainedUptime, isNull);
      final first = _Thing();
      final second = _Thing();
      final firstTrigger = tracker.expectDeletionOnTriggerFor(first, 'first');
      final secondTrigger = tracker.expectDeletionOnTriggerFor(second, 'second');

      time.advance(const Duration(seconds: 1));
      firstTrigger.markRetainedIfStronglyReachable();
      time.advance(const Duration(seconds: 2));
      secondTrigger.markRetainedIfStronglyReachable();

      expect(tracker.newestRetainedUptime, const Duration(seconds: 3));
    });

    test('logs what it watches, with the reason when there is one, when verbose', () {
      final log = captureLog(verbose: true);
      final thing = _Thing();

      tracker.expectDeletionOnTriggerFor(thing, 'it was disposed');
      tracker.expectDeletionOnTriggerFor(thing, '');

      expect(log.lines, [
        'Watching instance of _Thing (it was disposed) with key k0',
        'Watching instance of _Thing with key k1',
      ]);
    });

    test('does not log every watched object by default: Flutter disposes hundreds on each navigation', () {
      final log = captureLog();
      final thing = _Thing();

      tracker.expectDeletionOnTriggerFor(thing, 'it was disposed');

      expect(log.lines, isEmpty);
    });

    test('keeps the creation stack it was given', () {
      final thing = _Thing();
      final stack = StackTrace.current;

      tracker.expectDeletionOnTriggerFor(thing, 'why', creationStack: stack);

      expect(tracker.trackedWeakReferences.single.creationStack, same(stack));
    });

    test('exposes the tracked and the retained references', () {
      final first = _Thing();
      final second = _Thing();
      tracker.expectDeletionOnTriggerFor(first, 'first').markRetainedIfStronglyReachable();
      tracker.expectDeletionOnTriggerFor(second, 'second');

      expect(tracker.trackedWeakReferences.map((reference) => reference.description), ['first', 'second']);
      expect(tracker.retainedWeakReferences.map((reference) => reference.description), ['first']);
    });
  });

  group('clearing', () {
    test('forgets what was tracked at or before a time, and keeps what came after', () {
      final objects = List.generate(4, (_) => _Thing());
      final triggers = <RetainTrigger>[];
      for (final object in objects) {
        triggers.add(tracker.expectDeletionOnTriggerFor(object, 'at ${time.now.inSeconds}'));
        time.advance(const Duration(seconds: 1));
      }
      // Watched at 0 s, 1 s, 2 s and 3 s.

      tracker.clearObjectsTrackedBefore(const Duration(seconds: 1));

      expect(tracker.trackedWeakReferences.map((reference) => reference.description), ['at 2', 'at 3']);
      expect(triggers[0].isStronglyReachable, isFalse);
      expect(triggers[1].isStronglyReachable, isFalse, reason: 'the boundary is inclusive');
      expect(triggers[2].isStronglyReachable, isTrue);
    });

    test('forgets retained objects too, so a reported object is not reported again', () {
      final thing = _Thing();
      tracker.expectDeletionOnTriggerFor(thing, 'why').markRetainedIfStronglyReachable();

      tracker.clearObjectsTrackedBefore(time.now);

      expect(tracker.retainedObjectCount, 0);
      expect(tracker.newestRetainedUptime, isNull);
    });

    test('clearing everything forgets everything', () {
      final first = _Thing();
      final second = _Thing();
      tracker.expectDeletionOnTriggerFor(first, 'first').markRetainedIfStronglyReachable();
      tracker.expectDeletionOnTriggerFor(second, 'second');

      tracker.clearAllObjectsTracked();

      expect(tracker.trackedObjectCount, 0);
      expect(tracker.retainedObjectCount, 0);
    });
  });

  group('snapshots', () {
    test('capture what is known about the retained objects that are alive', () {
      final retained = _Thing();
      final notYet = _Thing();
      time.advance(const Duration(seconds: 1));
      tracker.expectDeletionOnTriggerFor(retained, 'retained', creationStack: StackTrace.current);
      tracker.expectDeletionOnTriggerFor(notYet, 'not yet');
      time.advance(const Duration(seconds: 5));
      tracker.trackedWeakReferences.first.retainedUptime = time.now;

      final snapshots = tracker.snapshotRetainedObjects();

      expect(snapshots, hasLength(1));
      final snapshot = snapshots.single;
      expect(snapshot.description, 'retained');
      expect(snapshot.type, _Thing);
      expect(snapshot.identityHash, identityHashCode(retained));
      expect(snapshot.watchUptime, const Duration(seconds: 1));
      expect(snapshot.retainedUptime, const Duration(seconds: 6));
      expect(snapshot.creationStack, isNotNull);
    });

    test('ask the VM for an id only when someone resolves it, because an id pins the object', () {
      final first = _Thing();
      final second = _Thing();
      tracker.expectDeletionOnTriggerFor(first, 'first').markRetainedIfStronglyReachable();
      tracker.expectDeletionOnTriggerFor(second, 'second').markRetainedIfStronglyReachable();
      final asked = <Object>[];

      final snapshots = tracker.snapshotRetainedObjects(
        objectIdOf: (object) {
          asked.add(object);
          return 'objects/${asked.length}';
        },
      );

      expect(asked, isEmpty, reason: 'taking the snapshot must not pin anything');
      expect(snapshots[1].resolveVmObjectId(), 'objects/1');
      expect(asked.single, same(second));
    });

    test('have no VM id when no way to get one is given', () {
      final thing = _Thing();
      tracker.expectDeletionOnTriggerFor(thing, 'why').markRetainedIfStronglyReachable();

      final snapshot = tracker.snapshotRetainedObjects().single;

      expect(snapshot.resolveVmObjectId(), isNull);
      expect(snapshot.isCollected, isFalse, reason: 'with no way to tell, it is not assumed gone');
    });

    test('say the object was collected once it is, and then have no VM id', () async {
      void watchAndRetain() => tracker.expectDeletionOnTriggerFor(_Thing(), 'temporary').markRetainedIfStronglyReachable();
      final kept = _Thing();
      tracker.expectDeletionOnTriggerFor(kept, 'kept').markRetainedIfStronglyReachable();
      watchAndRetain();
      final snapshots = tracker.snapshotRetainedObjects(objectIdOf: (_) => 'objects/1');
      expect(snapshots.map((s) => s.isCollected), [false, false]);

      await forceGc();

      final byDescription = {for (final s in snapshots) s.description: s};
      expect(byDescription['kept']!.isCollected, isFalse);
      expect(byDescription['kept']!.resolveVmObjectId(), 'objects/1');
      expect(byDescription['temporary']!.isCollected, isTrue);
      expect(byDescription['temporary']!.resolveVmObjectId(), isNull);
    });
  });

  group('with the real garbage collector', () {
    test('an object that was collected is no longer tracked', () async {
      void watchTemporary() => tracker.expectDeletionOnTriggerFor(_Thing(), 'temporary');
      watchTemporary();

      await forceGc();

      expect(tracker.trackedObjectCount, 0);
      expect(tracker.hasTrackedObjects, isFalse);
    });

    test('an object that stays reachable is still tracked after a GC, and can be retained', () async {
      final kept = _Thing();
      final trigger = tracker.expectDeletionOnTriggerFor(kept, 'kept');

      await forceGc();
      trigger.markRetainedIfStronglyReachable();

      expect(tracker.trackedObjectCount, 1);
      expect(tracker.retainedObjectCount, 1);
      expect(kept, isNotNull);
    });

    test('an object collected before its delay ended is never retained', () async {
      late RetainTrigger trigger;
      void watchTemporary() => trigger = tracker.expectDeletionOnTriggerFor(_Thing(), 'temporary');
      watchTemporary();

      await forceGc();
      trigger.markRetainedIfStronglyReachable();

      expect(tracker.retainedObjectCount, 0);
      expect(retainedNotifications, 0, reason: 'nothing is retained, so nothing is announced');
      expect(trigger.isStronglyReachable, isFalse);
      expect(trigger.isRetained, isFalse);
    });

    test('a retained object that is collected afterwards stops counting', () async {
      void watchAndRetain() => tracker.expectDeletionOnTriggerFor(_Thing(), 'temporary').markRetainedIfStronglyReachable();
      watchAndRetain();

      await forceGc();

      expect(tracker.retainedObjectCount, 0);
      expect(tracker.newestRetainedUptime, isNull);
    });

    test('a snapshot skips an object that was collected', () async {
      void watchAndRetain() => tracker.expectDeletionOnTriggerFor(_Thing(), 'temporary').markRetainedIfStronglyReachable();
      watchAndRetain();

      await forceGc();

      expect(tracker.snapshotRetainedObjects(), isEmpty);
    });

    test('a collected object is no longer counted, whether or not the finalizer ever ran', () async {
      void watchAndRetain() => tracker.expectDeletionOnTriggerFor(_Thing(), 'temporary').markRetainedIfStronglyReachable();
      watchAndRetain();
      expect(tracker.retainedObjectCount, 1);

      await forceGc();

      expect(tracker.retainedObjectCount, 0);
      expect(tracker.hasRetainedObjects, isFalse);
      expect(tracker.trackedObjectCount, 0);
      expect(tracker.retainedWeakReferences, isEmpty);
      expect(tracker.trackedWeakReferences, isEmpty);
    });

    test('a reference reports cleared once its object is collected, without reading it', () async {
      late KeyedWeakReference reference;
      void watchTemporary() {
        tracker.expectDeletionOnTriggerFor(_Thing(), 'temporary');
        reference = tracker.trackedWeakReferences.single;
      }

      watchTemporary();
      expect(reference.isCleared, isFalse);

      await forceGc();

      expect(reference.isCleared, isTrue);
      expect(reference.getAndLeakReferent(), isNull);
    });
  });
}
