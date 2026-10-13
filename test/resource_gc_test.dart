import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/internal_leak_sentry.dart';
import 'package:leak_sentry/core/leak_report_hub.dart';
import 'package:leak_sentry/core/resource_tracker.dart';
import 'package:leak_sentry/leak_sentry.dart';

import 'helpers/force_gc.dart';

class _Resource {}

/// Waits, in real time, for a collection to have run the finalizers it
/// scheduled: they run on the event loop some time after the GC.
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  tearDown(LeakSentry.resetForTesting);

  group('a resource tracked with the real finalizer', () {
    late LeakReportHub hub;
    late ResourceTracker tracker;

    setUp(() {
      hub = LeakReportHub();
      tracker = ResourceTracker(onLeak: hub.add);
    });

    test('is reported when it is collected without having been closed: tracking it does not keep it alive', () async {
      void trackAndDrop() => tracker.trackResource(_Resource(), label: 'dropped');
      trackAndDrop();

      await forceGc();
      await _until(() => hub.leakHistory.isNotEmpty);

      expect(hub.leakHistory, hasLength(1));
      expect(hub.leakHistory.single.reason, 'dropped');
      expect(hub.leakHistory.single.confidence, LeakConfidence.resourceNeverClosed);
      expect(hub.leakHistory.single.type, _Resource);
    });

    test('is not reported when it was closed before it was collected', () async {
      void trackCloseAndDrop() => tracker.trackResource(_Resource(), label: 'closed').markClosed();
      trackCloseAndDrop();

      await forceGc();
      await pumpEventQueue(times: 100);

      expect(hub.leakHistory, isEmpty);
    });

    test('is not reported while it is still in use', () async {
      final inUse = _Resource();
      tracker.trackResource(inUse, label: 'in use');

      await forceGc();
      await pumpEventQueue(times: 100);

      expect(hub.leakHistory, isEmpty);
      expect(inUse, isNotNull);
    });
  });

  group('a TrackedStreamController', () {
    late InternalLeakSentry engine;

    setUp(() {
      engine = InternalLeakSentry(testEnvironment: () => null);
      InternalLeakSentry.instance = engine;
    });

    test('that was closed is not reported when it is collected: close() marks it closed', () async {
      void useAndClose() {
        final controller = TrackedStreamController<int>(label: 'closed controller');
        // Not awaited: the future of a single-subscription controller only
        // completes once something listens. The controller is closed at once.
        unawaited(controller.close());
      }

      useAndClose();
      await forceGc();
      await pumpEventQueue(times: 100);

      expect(engine.hub.leakHistory, isEmpty);
    });

    test('that was never closed is reported when it is collected, by its label', () async {
      void useAndForget() => TrackedStreamController<int>(label: 'forgotten controller');
      useAndForget();

      await forceGc();
      await _until(() => engine.hub.leakHistory.isNotEmpty);

      expect(engine.hub.leakHistory.single.reason, 'forgotten controller');
      expect(engine.hub.leakHistory.single.confidence, LeakConfidence.resourceNeverClosed);
    });

    test('a broadcast one is tracked too', () async {
      void useAndForget() => TrackedStreamController<int>.broadcast(label: 'forgotten broadcast');
      useAndForget();

      await forceGc();
      await _until(() => engine.hub.leakHistory.isNotEmpty);

      expect(engine.hub.leakHistory.single.reason, 'forgotten broadcast');
    });
  });
}
