import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/leak_report_hub.dart';
import 'package:leak_sentry/core/resource_tracker.dart';
import 'package:leak_sentry/models/resource_token.dart';

import 'fakes/fake_object_finalizer.dart';

class _Resource {}

void main() {
  late FakeObjectFinalizer<ResourceToken> fakeFinalizer;
  late LeakReportHub hub;
  late ResourceTracker tracker;

  setUp(() {
    hub = LeakReportHub();
    tracker = ResourceTracker(
      onLeak: hub.add,
      finalizerFactory: (callback) {
        fakeFinalizer = FakeObjectFinalizer<ResourceToken>(callback);
        return fakeFinalizer;
      },
    );
  });

  test('repeated identical leaks dedupe into one report with an incrementing occurrenceCount', () async {
    final emittedSignatures = <String>[];
    hub.leaks.listen((report) => emittedSignatures.add(report.signature));

    final tokenA = tracker.trackResource(_Resource(), label: 'same label');
    fakeFinalizer.simulateCollected(tokenA);

    final tokenB = tracker.trackResource(_Resource(), label: 'same label');
    fakeFinalizer.simulateCollected(tokenB);

    await pumpEventQueue();

    expect(hub.leakHistory, hasLength(1));
    expect(hub.leakHistory.single.occurrenceCount, 2);
    expect(emittedSignatures, hasLength(1));
  });

  test('leaks with different labels do not dedupe together', () {
    final tokenA = tracker.trackResource(_Resource(), label: 'label a');
    fakeFinalizer.simulateCollected(tokenA);

    final tokenB = tracker.trackResource(_Resource(), label: 'label b');
    fakeFinalizer.simulateCollected(tokenB);

    expect(hub.leakHistory, hasLength(2));
  });
}
