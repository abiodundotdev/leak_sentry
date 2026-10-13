import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/object_watcher/delayed_executor.dart';
import 'package:leak_sentry/object_watcher/deletable_object_reporter.dart';
import 'package:leak_sentry/object_watcher/retained_object_tracker.dart';

import 'fakes/fake_time.dart';

class _Thing {}

class _Other {}

class _RecordingReporter implements DeletableObjectReporter {
  final List<(Object, String)> reported = [];

  @override
  TrackedObjectReachability expectDeletionFor(Object target, String reason) {
    reported.add((target, reason));
    return const UntrackedObjectReachability();
  }
}

void main() {
  group('filteringInstances', () {
    test('passes on an instance the filter accepts', () {
      final delegate = _RecordingReporter();
      final reporter = delegate.filteringInstances<_Thing>((_) => true);
      final thing = _Thing();

      reporter.expectDeletionFor(thing, 'why');

      expect(delegate.reported, [(thing, 'why')]);
    });

    test('swallows an instance the filter rejects, and says it is not retained', () {
      final delegate = _RecordingReporter();
      final reporter = delegate.filteringInstances<_Thing>((_) => false);

      final reachability = reporter.expectDeletionFor(_Thing(), 'why');

      expect(delegate.reported, isEmpty);
      expect(reachability.isRetained, isFalse);
      expect(reachability.isStronglyReachable, isFalse);
      expect(reachability.isDeletable, isTrue);
    });

    test('always passes on objects of other types', () {
      final delegate = _RecordingReporter();
      final reporter = delegate.filteringInstances<_Thing>((_) => false);
      final other = _Other();

      reporter.expectDeletionFor(other, 'why');

      expect(delegate.reported, [(other, 'why')]);
    });

    test('hands the filter the instance', () {
      final delegate = _RecordingReporter();
      final thing = _Thing();
      _Thing? seen;
      final reporter = delegate.filteringInstances<_Thing>((target) {
        seen = target;
        return true;
      });

      reporter.expectDeletionFor(thing, 'why');

      expect(seen, same(thing));
    });
  });

  group('delayed and default-delay reporters', () {
    late FakeTime time;
    late WeakReferenceRetainedObjectTracker tracker;
    late DelayedDeletableObjectReporter delayed;

    setUp(() {
      time = FakeTime();
      tracker = WeakReferenceRetainedObjectTracker(clock: time.clock, onObjectRetained: () {});
      delayed = DelayedDeletableObjectReporter(
        deletableObjectReporter: tracker,
        delayedExecutor: SchedulerDelayedExecutor(scheduler: time, clock: time.clock),
      );
    });

    test('an object is retained after the delay it was given', () {
      final thing = _Thing();

      final reachability = delayed.expectDelayedDeletionFor(thing, 'why', const Duration(seconds: 3));

      time.advance(const Duration(milliseconds: 2999));
      expect(reachability.isRetained, isFalse);
      time.advance(const Duration(milliseconds: 1));
      expect(reachability.isRetained, isTrue);
      expect(tracker.retainedObjectCount, 1);
    });

    test('objects with different delays are retained at their own times', () {
      final slow = _Thing();
      final fast = _Thing();
      final slowReachability = delayed.expectDelayedDeletionFor(slow, 'slow', const Duration(seconds: 10));
      final fastReachability = delayed.expectDelayedDeletionFor(fast, 'fast', const Duration(seconds: 1));

      time.advance(const Duration(seconds: 1));

      expect(fastReachability.isRetained, isTrue);
      expect(slowReachability.isRetained, isFalse);
    });

    test('the default-delay reporter always uses its delay', () {
      final reporter = DefaultDelayDeletableObjectReporter(
        defaultDelay: const Duration(seconds: 5),
        delayedReporter: delayed,
      );
      final thing = _Thing();

      final reachability = reporter.expectDeletionFor(thing, 'why');

      time.advance(const Duration(seconds: 4));
      expect(reachability.isRetained, isFalse);
      time.advance(const Duration(seconds: 1));
      expect(reachability.isRetained, isTrue);
    });
  });
}
