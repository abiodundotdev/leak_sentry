import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/resource_token.dart';
import 'package:leak_sentry/models/retaining_element.dart';

import 'helpers/capture_log.dart';
import 'helpers/engine_fixture.dart';

class _Thing {}

class _OtherThing {}

/// `Registry.things` holds the leaked object, as the VM would say it.
const _heldByRegistry = RetainingPathInfo(
  gcRootType: 'user global',
  hops: ['Leaked', 'Registry.things'],
  elements: [
    RetainingElement(kind: RetainingElementKind.instance, className: 'Leaked', libraryUri: 'package:app/leaked.dart', objectId: 'objects/leaked'),
    RetainingElement(kind: RetainingElementKind.staticField, className: 'Registry', libraryUri: 'package:app/registry.dart', field: 'things'),
  ],
);

/// Dumps the heap the way the engine does, or fails when told to.
class _FlakyDumper implements HeapDumper {
  _FlakyDumper(this._inner);

  final HeapDumper _inner;
  Object? error;

  @override
  Future<RetainedObjectsDump> dumpHeap() async {
    final failure = error;
    if (failure != null) throw failure;
    return _inner.dumpHeap();
  }
}

class _ThrowingCatalog extends LeakCatalog {
  int calls = 0;

  @override
  void onEvent(LeakSentryEvent event) {
    calls++;
    throw StateError('the catalog is broken');
  }
}

class _RecordingListener implements LeakSentryEventListener {
  final List<LeakSentryEvent> heard = [];

  @override
  void onEvent(LeakSentryEvent event) => heard.add(event);
}

const _delay = Duration(seconds: 5);

void main() {
  late EngineFixture f;
  late CapturingLogger log;
  // The things that leak are kept here, so that they stay retained.
  late List<Object> things;

  _Thing watchThing() {
    final thing = _Thing();
    things.add(thing);
    f.engine.objectWatcher.watch(thing, 'a thing was disposed');
    return thing;
  }

  setUp(() {
    log = captureLog();
    things = [];
    f = EngineFixture();
    f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
    f.engine.install(watchers: const []);
  });

  tearDown(() => f.engine.dispose());

  group('the engine feeds the catalog', () {
    test('a leak that is found shows up as a scan and as a distinct leak', () async {
      watchThing();

      await f.time.elapse(_delay);

      final scan = f.engine.catalog.scans.single;
      expect(scan.status, ScanStatus.succeeded);
      expect(scan.heldCount, 1);
      expect(scan.trigger, contains('1 retained objects'));
      expect(scan.leaks, hasLength(1));
      expect(scan.newCount, 1);

      final group = f.engine.catalog.groups.single;
      expect(group.leakedType, '_Thing');
      expect(group.reason, 'a thing was disposed');
      expect(group.count, 1);
      expect(group.isUnread, isTrue);
      expect(group.firstSeen, EngineFixture.epoch.add(_delay), reason: 'the times are the engine\'s clock, not the machine\'s');
      expect(group.instances.single.watchSite, isNotNull, reason: 'an object that was watched by hand says where');
    });

    test('the hub and the catalog agree on what was found, each in its own way', () async {
      watchThing();
      await f.time.elapse(_delay);
      await f.time.elapse(const Duration(seconds: 61));
      watchThing(); // from the same line again, so it is the same leak
      await f.time.elapse(_delay);

      expect(f.engine.hub.leakHistory, hasLength(1), reason: 'the hub reports a leak once');
      expect(f.engine.hub.leakHistory.single.occurrenceCount, 2);
      expect(f.engine.catalog.groups, hasLength(1));
      expect(f.engine.catalog.groups.single.count, 2);
      expect(f.engine.catalog.scans, hasLength(2));
      expect(f.engine.catalog.scans.map((scan) => scan.newCount), [0, 1]);
    });

    test('hears every event even when the config replaces the listeners', () async {
      final custom = _RecordingListener();
      f.engine.config = f.engine.config.copyWith(eventListeners: [custom]);
      watchThing();

      await f.time.elapse(_delay);

      expect(custom.heard.whereType<HeapDumpEvent>(), hasLength(1));
      final scan = f.engine.catalog.scans.single;
      expect(scan.status, ScanStatus.running, reason: 'nothing analyzes the dump, as the config asked');
      expect(scan.heldCount, 1);
    });

    test('a failed dump is a scan of its own, and the dump after it is another', () async {
      final dumper = _FlakyDumper(RetainedSetHeapDumper(tracker: f.engine.objectWatcher.tracker, vm: f.vm, uptime: f.time.clock));
      f.engine.config = f.engine.config.copyWith(heapDumper: dumper);
      dumper.error = StateError('no space');
      watchThing();

      await f.time.elapse(_delay);

      expect(f.engine.catalog.scans.single.status, ScanStatus.failed);
      expect(f.engine.catalog.scans.single.failure, contains('no space'));
      expect(f.engine.catalog.scans.single.willRetry, isTrue);

      dumper.error = null;
      await f.time.elapse(const Duration(seconds: 5)); // the retry

      expect(f.engine.catalog.scans.map((scan) => scan.status), [ScanStatus.succeeded, ScanStatus.failed]);
      expect(f.engine.catalog.groups, hasLength(1));
    });

    test('a failed dump after a good one does not turn the good one into a failure', () async {
      final dumper = _FlakyDumper(RetainedSetHeapDumper(tracker: f.engine.objectWatcher.tracker, vm: f.vm, uptime: f.time.clock));
      f.engine.config = f.engine.config.copyWith(heapDumper: dumper);
      watchThing();
      await f.time.elapse(_delay);
      final good = f.engine.catalog.scans.single;
      expect(good.status, ScanStatus.succeeded);

      // The next dump's events carry the id of the good one.
      dumper.error = StateError('no space');
      await f.time.elapse(const Duration(seconds: 61));
      watchThing();
      await f.time.elapse(_delay);

      final scans = f.engine.catalog.scans;
      expect(scans.map((scan) => scan.status), [ScanStatus.failed, ScanStatus.succeeded]);
      expect(scans.last.id, good.id);
      expect(scans.last.leaks, hasLength(1), reason: 'the good scan keeps what it found');
      expect(f.eventsOf<HeapDumpFailedEvent>().single.uniqueId, good.id, reason: 'the trap is real: the ids are the same');
    });

    test('a user request is a scan too', () async {
      watchThing();
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 5);
      await f.time.elapse(_delay);
      expect(f.engine.catalog.scans, isEmpty);

      await f.engine.dumpHeap();

      expect(f.engine.catalog.scans.single.trigger, 'user request');
      expect(f.engine.catalog.groups.single.count, 1);
    });

    test('a broken catalog cannot stop the heap from being dumped, or the listeners from hearing it', () async {
      final broken = _ThrowingCatalog();
      final other = EngineFixture(catalog: broken);
      final listener = _RecordingListener();
      other.engine.config = LeakSentryConfig(
        retainedVisibleThreshold: 1,
        eventListeners: [listener, ...other.engine.defaultEventListeners],
      );
      other.engine.install(watchers: const []);
      final thing = _Thing();
      other.engine.objectWatcher.watch(thing, 'why');

      await other.time.elapse(_delay);

      expect(broken.calls, greaterThan(0));
      expect(log.lines, contains('The leak catalog failed on HeapDumpEvent'));
      expect(log.errors, contains(isA<StateError>()));
      expect(listener.heard.whereType<HeapDumpEvent>(), hasLength(1));
      expect(other.engine.hub.leakHistory, hasLength(1), reason: 'the analysis still ran');
      expect(thing, isNotNull);
      other.engine.dispose();
    });

    test('clearing the leaks clears the hub and the catalog', () async {
      watchThing();
      await f.time.elapse(_delay);

      f.engine.clearLeaks();

      expect(f.engine.hub.leakHistory, isEmpty);
      expect(f.engine.catalog.groups, isEmpty);
      expect(f.engine.catalog.scans, isEmpty);
    });

    test('a leaked resource is counted, once for each one collected', () {
      // Acquired at one place, as the controllers a loop makes are.
      ResourceToken acquire() => f.engine.resourceTracker.trackResource(_Thing(), label: 'PageFour.controller');
      final first = acquire();
      final second = acquire();

      f.finalizer.simulateCollected(first);
      f.finalizer.simulateCollected(second);

      final group = f.engine.catalog.groups.single;
      expect(group.kind, LeakKind.resource);
      expect(group.count, 2);
      expect(group.instances.single.creationSite, isNotNull);
      expect(f.engine.hub.leakHistory.single.occurrenceCount, 2);
    });

    test('resources of one label acquired in different places are different leaks, each with its own place', () {
      final first = f.engine.resourceTracker.trackResource(_Thing(), label: 'StreamController<int>');
      final second = f.engine.resourceTracker.trackResource(_Thing(), label: 'StreamController<int>');

      f.finalizer.simulateCollected(first);
      f.finalizer.simulateCollected(second);

      expect(f.engine.catalog.groups, hasLength(2));
      final lines = {for (final group in f.engine.catalog.groups) group.instances.single.creationSite!.line};
      expect(lines, hasLength(2), reason: 'two lines of this file');
      expect(f.engine.hub.leakHistory, hasLength(1), reason: 'the hub, as before, reports one signature once');
    });

    test('a leaked resource on the web says it has no line to show', () {
      final web = EngineFixture(web: true);
      final token = web.engine.resourceTracker.trackResource(_Thing(), label: 'web resource');

      web.finalizer.simulateCollected(token);

      final instance = web.engine.catalog.groups.single.instances.single;
      expect(instance.creationSite, isNull);
      expect(instance.creationSiteGap, CreationSiteGap.web);
      web.engine.dispose();
    });

    test('a scan that finishes after the engine is disposed is ignored', () async {
      final gate = Completer<void>();
      f.vm.retainingPathGate = () => gate.future;
      watchThing();
      await f.time.elapse(_delay);
      expect(f.engine.catalog.runningScan, isNotNull);

      f.engine.dispose();
      gate.complete();
      await f.settle();

      expect(f.engine.catalog.scans.single.status, ScanStatus.running);
    });
  });

  group('the engine knows when a screen is open', () {
    test('the flag follows the number of screens that are open, a moment after', () async {
      expect(f.engine.screenOpen.value, isFalse);
      expect(f.engine.isScreenOpen, isFalse);

      f.engine.screenOpened();
      expect(f.engine.isScreenOpen, isTrue, reason: 'asking has no wait');
      await pumpEventQueue();
      expect(f.engine.screenOpen.value, isTrue);

      f.engine.screenOpened();
      f.engine.screenClosed();
      await pumpEventQueue();
      expect(f.engine.screenOpen.value, isTrue, reason: 'one screen is still open');

      f.engine.screenClosed();
      await pumpEventQueue();
      expect(f.engine.screenOpen.value, isFalse);
      expect(f.engine.isScreenOpen, isFalse);
    });

    test('a screen that closes without having opened cannot make the next one look closed', () async {
      f.engine.screenClosed();
      f.engine.screenOpened();
      await pumpEventQueue();

      expect(f.engine.isScreenOpen, isTrue);
      expect(f.engine.screenOpen.value, isTrue);
    });

    test('a flag that changes after the engine is disposed is left alone', () async {
      f.engine.screenOpened();
      f.engine.dispose();

      await pumpEventQueue();

      expect(f.engine.screenOpen.dispose, returnsNormally, reason: 'disposed once already, which is fine');
    });

    test('the flag tells its listeners once for each change', () async {
      var told = 0;
      f.engine.screenOpen.addListener(() => told++);

      f.engine.screenOpened();
      f.engine.screenOpened();
      await pumpEventQueue();
      f.engine.screenClosed();
      f.engine.screenClosed();
      await pumpEventQueue();

      expect(told, 2);
    });
  });

  group('the engine owns what the screens read', () {
    test('disposing it disposes the catalog and the notice controller', () {
      f.engine.dispose();

      expect(() => f.engine.catalog.addListener(() {}), throwsFlutterError);
      expect(() => f.engine.notices.addListener(() {}), throwsFlutterError);
    });

    test('one that was given a catalog uses it', () {
      final given = LeakCatalog();
      final other = EngineFixture(catalog: given);

      expect(other.engine.catalog, same(given));
      other.engine.dispose();
    });

    test('its counts are its own: the hub changing a report afterwards changes nothing here', () async {
      watchThing();
      await f.time.elapse(_delay);
      final report = f.engine.hub.leakHistory.single;

      report.occurrenceCount += 50;

      expect(f.engine.catalog.groups.single.count, 1);
      expect(report, isA<LeakReport>());
    });
  });

  group('the path of a leak', () {
    test('is worked out, and the leak is called by the likely cause of it', () async {
      f.vm.path = _heldByRegistry;
      watchThing();

      await f.time.elapse(_delay);

      final group = f.engine.catalog.groups.single;
      expect(group.title, 'Registry.things');
      expect(group.leakedTypes, ['_Thing']);
      expect(group.instances.single.trace!.fingerprint, 'package:app/registry.dart:Registry:things');
      expect(f.engine.hub.leakHistory.single.trace, same(group.instances.single.trace), reason: 'the report the API gives has it too');
    });

    test('is one leak for what is held the same way, whatever it is, where the hub has one for each', () async {
      f.vm.path = _heldByRegistry;
      final other = _OtherThing();
      things.add(other);
      f.engine.objectWatcher.watch(other, 'another thing was disposed');
      watchThing();

      await f.time.elapse(_delay);

      expect(f.engine.hub.leakHistory, hasLength(2));
      expect(f.engine.catalog.groups, hasLength(1));
      expect(f.engine.catalog.groups.single.count, 2);
      expect(f.engine.catalog.groups.single.leakedTypes.toSet(), {'_Thing', '_OtherThing'});
      expect(f.engine.catalog.scans.single.leaks, hasLength(2));
      expect(f.engine.catalog.scans.single.leakCount, 1);
    });

    test('asks the VM about no fields when nothing on the path can be told by them', () async {
      f.vm.path = _heldByRegistry;
      watchThing();

      await f.time.elapse(_delay);

      expect(f.vm.fieldReads, isEmpty);
    });
  });
}
