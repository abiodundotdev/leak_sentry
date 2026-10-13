import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/leak_sentry.dart';

class _Thing {}

void main() {
  tearDown(LeakSentry.resetForTesting);

  test('public barrel exports the full API surface', () {
    expect(LeakSentry.leaks, isA<Stream<LeakReport>>());
    expect(LeakSentry.leakHistory, isEmpty);
    expect(LeakSentry.events, isA<Stream<LeakSentryEvent>>());
    expect(LeakSentry.stats, isA<LeakSentryStats>());
    expect(LeakSentry.config, isA<LeakSentryConfig>());
    expect(LeakSentry.objectWatcher, isA<ObjectWatcher>());
    expect(LeakSentry.defaultEventListeners, isNotEmpty);
    expect(LeakSentry.defaultWatchers(), everyElement(isA<InstallableWatcher>()));
  });

  test('CreationSite, the type of LeakReport.creationSite, is exported', () {
    final report = LeakReport(
      type: String,
      reason: 'test',
      firstObservedAt: DateTime(2026),
      detectedAt: DateTime(2026),
      confidence: LeakConfidence.resourceNeverClosed,
      signature: 'test',
      creationSite: const CreationSite(uri: 'package:app/page.dart', line: 1),
    );

    expect(report.creationSite, isA<CreationSite>());
    expect(report.toString(), contains('createdAt: package:app/page.dart:1'));
  });

  test('the types that explain a report with no site or no path are exported', () {
    final report = LeakReport(
      type: String,
      reason: 'test',
      firstObservedAt: DateTime(2026),
      detectedAt: DateTime(2026),
      confidence: LeakConfidence.retainedAfterGc,
      signature: 'test',
      watchSite: const CreationSite(uri: 'package:app/page.dart', line: 2),
      classSite: const CreationSite(uri: 'package:app/page.dart', line: 3),
      creationSiteGap: CreationSiteGap.onlyFrameworkFrames,
      pathGap: RetainingPathGap.noVmService,
      retainingPath: const RetainingPathInfo(
        gcRootType: 'user global',
        hops: ['Leaky'],
        elements: [RetainingElement(kind: RetainingElementKind.instance, className: 'Leaky')],
      ),
    );

    expect(report.creationSiteGap, CreationSiteGap.onlyFrameworkFrames);
    expect(report.pathGap, RetainingPathGap.noVmService);
    expect(report.retainingPath!.elements.single.className, 'Leaky');
  });

  test('TrackedStreamController is usable through the barrel export', () {
    final controller = TrackedStreamController<int>();
    expect(controller.isClosed, isFalse);
    // Not awaited: a single-subscription StreamController's close() future
    // only resolves once a listener has subscribed, which this smoke test
    // deliberately never does -- `isClosed` flips synchronously regardless.
    unawaited(controller.close());
    expect(controller.isClosed, isTrue);
  });

  test('LeakSentry.expectNoLeaks does not throw when nothing has leaked', () {
    expect(LeakSentry.expectNoLeaks, returnsNormally);
  });

  group('installing', () {
    test('is off until install is called, which turns it on once', () {
      expect(LeakSentry.isInstalled, isFalse);

      LeakSentry.install(watchers: const []);

      expect(LeakSentry.isInstalled, isTrue);
      expect(() => LeakSentry.install(watchers: const []), throwsStateError);
    });

    test('the retained delay is honoured, and retained objects are counted', () async {
      LeakSentry.install(retainedDelay: Duration.zero, watchers: const []);
      final thing = _Thing();

      LeakSentry.objectWatcher.watch(thing, 'a reason');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(LeakSentry.retainedObjectCount, 1);
      expect(thing, isNotNull);
    });

    test('watch is shorthand for objectWatcher.watch, with an optional reason', () async {
      LeakSentry.install(retainedDelay: Duration.zero, watchers: const []);
      final thing = _Thing();
      final other = _Thing();

      LeakSentry.watch(thing, reason: 'because');
      LeakSentry.watch(other);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final descriptions = LeakSentry.objectWatcher.tracker.trackedWeakReferences.map((reference) => reference.description);
      expect(descriptions, ['because', 'unknown: reason not provided']);
      expect(thing, isNotNull);
      expect(other, isNotNull);
    });

    test('installObjectWatcher counts retained objects without dumping the heap', () async {
      LeakSentry.installObjectWatcher(retainedDelay: Duration.zero, watchers: const []);
      final thing = _Thing();

      LeakSentry.watch(thing);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(LeakSentry.retainedObjectCount, 1);
      await LeakSentry.dumpHeap(forceDump: true);
      expect(LeakSentry.leakHistory, isEmpty);
      expect(thing, isNotNull);
    });

    test('watching before it is installed is ignored', () {
      final thing = _Thing();

      expect(() => LeakSentry.watch(thing), returnsNormally);

      expect(LeakSentry.retainedObjectCount, 0);
    });
  });

  group('configuration', () {
    test('can be changed and read back', () {
      LeakSentry.config = LeakSentry.config.copyWith(retainedVisibleThreshold: 9, dumpHeap: false);

      expect(LeakSentry.config.retainedVisibleThreshold, 9);
      expect(LeakSentry.config.dumpHeap, isFalse);
    });

    test('copyWith keeps what it is not told to change', () {
      const base = LeakSentryConfig(retainedVisibleThreshold: 3, enableRetainingPathAnalysis: false, maxRetainingPathLookups: 4);

      final copy = base.copyWith(dumpHeap: false);

      expect(copy.dumpHeap, isFalse);
      expect(copy.retainedVisibleThreshold, 3);
      expect(copy.enableRetainingPathAnalysis, isFalse);
      expect(copy.maxRetainingPathLookups, 4);
      expect(copy.heapDumper, isNull);
      expect(copy.eventListeners, isNull);
    });

    test('defaults to dumping the heap, a visible threshold of 5 and retaining-path analysis', () {
      const config = LeakSentryConfig();

      expect(config.dumpHeap, isTrue);
      expect(config.retainedVisibleThreshold, 5);
      expect(config.enableRetainingPathAnalysis, isTrue);
    });

    test('event listeners can be added to the defaults', () {
      final listener = _Listener();

      LeakSentry.config = LeakSentry.config.copyWith(eventListeners: [...LeakSentry.defaultEventListeners, listener]);

      expect(LeakSentry.config.eventListeners, hasLength(LeakSentry.defaultEventListeners.length + 1));
    });
  });

  group('resources', () {
    test('trackResource returns a token that can mark the resource closed', () {
      final token = LeakSentry.trackResource(_Thing(), label: 'a resource');

      expect(token.label, 'a resource');
      expect(token.isClosed, isFalse);
      token.markClosed();
      expect(token.isClosed, isTrue);
    });
  });

  test('resetForTesting gives the next test a fresh, uninstalled instance', () {
    LeakSentry.install(watchers: const []);

    LeakSentry.resetForTesting();

    expect(LeakSentry.isInstalled, isFalse);
    expect(LeakSentry.leakHistory, isEmpty);
  });
}

class _Listener implements LeakSentryEventListener {
  @override
  void onEvent(LeakSentryEvent event) {}
}
