import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/leak_report_hub.dart';
import 'package:leak_sentry/core/resource_tracker.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/leak_report.dart';
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

  test('resource closed before finalization: no leak', () {
    final token = tracker.trackResource(_Resource(), label: 'test resource');
    token.markClosed();
    fakeFinalizer.simulateCollected(token);

    expect(hub.leakHistory, isEmpty);
  });

  test('resource finalized while still open: reports a leak with the acquisition stack trace', () {
    final token = tracker.trackResource(_Resource(), label: 'test resource');
    fakeFinalizer.simulateCollected(token);

    expect(hub.leakHistory, hasLength(1));
    final leak = hub.leakHistory.single;
    expect(leak.confidence, LeakConfidence.resourceNeverClosed);
    expect(leak.reason, 'test resource');
    expect(leak.type, _Resource);
    expect(leak.acquiredAt, isNotNull);
  });

  test('a leaked resource reports the line of application code that started tracking it', () {
    final token = tracker.trackResource(_Resource(), label: 'test resource');
    fakeFinalizer.simulateCollected(token);

    final site = hub.leakHistory.single.creationSite;
    expect(site, isNotNull);
    expect(site!.uri, endsWith('resource_tracking_test.dart'));
  });

  test('on the web a leaked resource has no line to show, and says why', () {
    final webTracker = ResourceTracker(
      onLeak: hub.add,
      isWeb: true,
      finalizerFactory: (callback) => fakeFinalizer = FakeObjectFinalizer<ResourceToken>(callback),
    );

    fakeFinalizer.simulateCollected(webTracker.trackResource(_Resource(), label: 'web resource'));

    final report = hub.leakHistory.single;
    expect(report.creationSite, isNull);
    expect(report.creationSiteGap, CreationSiteGap.web);
    expect(report.acquiredAt, isNotNull, reason: 'the stack that was captured is still there to read');
  });

  test('a leaked resource whose line is known has no reason to give for not knowing it', () {
    final token = tracker.trackResource(_Resource(), label: 'test resource');
    fakeFinalizer.simulateCollected(token);

    final report = hub.leakHistory.single;
    expect(report.creationSite, isNotNull);
    expect(report.creationSiteGap, isNull);
    expect(report.watchSite, isNull);
    expect(report.pathGap, isNull, reason: 'a resource leak is never given a retaining path');
  });

  test('the label defaults to the type of the resource', () {
    final token = tracker.trackResource(_Resource());

    expect(token.label, '_Resource');
    expect(token.type, _Resource);
  });
}
