import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/heap_analysis.dart';
import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/object_watcher/keyed_weak_reference.dart';

class _Page {}

class _Other {}

RetainedObjectSnapshot _snapshot(String key) => RetainedObjectSnapshot(
  key: key,
  description: 'a page was disposed',
  type: _Page,
  identityHash: key.hashCode,
  watchUptime: Duration.zero,
  retainedUptime: const Duration(seconds: 5),
  watchedAt: DateTime(2026),
);

RetainedObjectsDump _dump(int held) => RetainedObjectsDump(
  objects: [for (var i = 0; i < held; i++) _snapshot('k$i')],
  dumpUptime: const Duration(seconds: 6),
  isolateId: 'isolates/1',
);

const _initState = CreationSite(uri: 'package:app/page.dart', member: '_PageState.initState', line: 42, column: 11);

LeakReport _report({
  Type type = _Page,
  String reason = 'a page was disposed',
  String? signature,
  int count = 1,
  CreationSite? creationSite = _initState,
  CreationSite? watchSite,
  CreationSite? classSite,
  CreationSiteGap? gap,
  RetainingPathInfo? path,
  RetainingPathGap? pathGap,
  LeakConfidence confidence = LeakConfidence.retainedAfterGc,
  StackTrace? acquiredAt,
}) => LeakReport(
  type: type,
  reason: reason,
  firstObservedAt: DateTime(2026),
  detectedAt: DateTime(2026),
  confidence: confidence,
  signature: signature ?? '$type|$reason|${creationSite?.line}',
  occurrenceCount: count,
  creationSite: creationSite,
  watchSite: watchSite,
  classSite: classSite,
  creationSiteGap: gap,
  retainingPath: path,
  pathGap: pathGap,
  acquiredAt: acquiredAt,
);

HeapDumpEvent _dumped(String id, {int held = 3, String reason = '3 retained objects, app is visible'}) =>
    HeapDumpEvent(id, dump: _dump(held), duration: const Duration(milliseconds: 20), reason: reason);

HeapAnalysisSucceededEvent _succeeded(String id, List<LeakReport> leaks, {int held = 3, int released = 0}) =>
    HeapAnalysisSucceededEvent(
      id,
      heapAnalysis: HeapAnalysisSuccess(
        dump: _dump(held),
        analysisDuration: const Duration(milliseconds: 30),
        leaks: leaks,
        unreachableObjectCount: released,
      ),
      newLeakSignatures: const {},
    );

HeapAnalysisFailedEvent _analysisFailed(String id, Object error) => HeapAnalysisFailedEvent(
  id,
  heapAnalysis: HeapAnalysisFailure(dump: _dump(1), analysisDuration: const Duration(milliseconds: 5), exception: error),
);

void main() {
  late DateTime now;
  late LeakCatalog catalog;
  late int notifications;

  setUp(() {
    now = DateTime(2026, 1, 1, 12);
    catalog = LeakCatalog(now: () => now);
    notifications = 0;
    catalog.addListener(() => notifications++);
  });

  tearDown(() => catalog.dispose());

  /// A whole scan: the heap is dumped and the analysis finds [leaks].
  void scan(String id, List<LeakReport> leaks, {int held = 3, int released = 0}) {
    catalog.onEvent(DumpingHeapEvent(id));
    catalog.onEvent(_dumped(id, held: held));
    catalog.onEvent(_succeeded(id, leaks, held: held, released: released));
  }

  group('distinct leaks', () {
    test('there are none at first', () {
      expect(catalog.groups, isEmpty);
      expect(catalog.leakCount, 0);
      expect(catalog.objectCount, 0);
      expect(catalog.unreadCount, 0);
      expect(catalog.scans, isEmpty);
      expect(catalog.isDumping, isFalse);
      expect(catalog.runningScan, isNull);
    });

    test('a leak a scan found is one distinct leak, with what is known about it', () {
      scan('a', [_report(count: 2)]);

      final group = catalog.groups.single;
      expect(group.kind, LeakKind.retained);
      expect(group.leakedType, '_Page');
      expect(group.title, '_Page');
      expect(group.reason, 'a page was disposed');
      expect(group.count, 2);
      expect(group.isUnread, isTrue);
      expect(group.firstSeen, now);
      expect(group.lastSeen, now);
      expect(group.instances.single.creationSite, _initState);
      expect(catalog.leakCount, 1);
      expect(catalog.objectCount, 2);
      expect(catalog.unreadCount, 1);
    });

    test('the same leak found by a later scan adds to its count and stays one leak', () {
      scan('a', [_report(count: 2)]);
      now = now.add(const Duration(minutes: 3));
      scan('b', [_report(count: 3)]);

      final group = catalog.groups.single;
      expect(group.count, 5);
      expect(group.firstSeen, DateTime(2026, 1, 1, 12));
      expect(group.lastSeen, DateTime(2026, 1, 1, 12, 3));
      expect(group.instances.single.count, 5);
      expect(group.instances.single.firstSeen, DateTime(2026, 1, 1, 12));
      expect(group.instances.single.lastSeen, DateTime(2026, 1, 1, 12, 3));
    });

    test('the counts are copies: the hub bumping the first report afterwards changes nothing', () {
      final first = _report(count: 2);
      scan('a', [first]);

      first.occurrenceCount += 10; // what LeakReportHub does to the first report of a signature

      expect(catalog.groups.single.count, 2);
      scan('b', [_report(count: 3)]);
      expect(catalog.groups.single.count, 5);
    });

    test('leaks with different signatures are different leaks', () {
      scan('a', [_report(creationSite: _initState), _report(type: _Other, reason: 'other', creationSite: null, gap: CreationSiteGap.notAnnounced)]);

      expect(catalog.groups.map((group) => group.leakedType), unorderedEquals(['_Page', '_Other']));
    });

    test('leaks are listed with the most objects first, and of those the most recent first', () {
      scan('a', [_report(signature: 'few', reason: 'few', count: 1)]);
      now = now.add(const Duration(minutes: 1));
      scan('b', [_report(signature: 'many', reason: 'many', count: 5)]);
      now = now.add(const Duration(minutes: 1));
      scan('c', [_report(signature: 'also-one', reason: 'also one', count: 1)]);

      expect(catalog.groups.map((group) => group.reason), ['many', 'also one', 'few']);
    });

    test('an older leak that is found again moves up when it then has more objects', () {
      scan('a', [_report(signature: 'a', reason: 'a', count: 2), _report(signature: 'b', reason: 'b', count: 2)]);
      expect(catalog.groups.map((group) => group.reason), ['a', 'b'], reason: 'a tie keeps the order they were found in');
      now = now.add(const Duration(minutes: 1));

      scan('b', [_report(signature: 'a', reason: 'a', count: 1)]);

      expect(catalog.groups.first.reason, 'a');
      expect(catalog.groups.first.count, 3);
    });

    test('one signature found at different times is one instance', () {
      scan('a', [_report(signature: 'one', count: 1)]);
      scan('b', [_report(signature: 'one', count: 1)]);

      expect(catalog.groups.single.instances, hasLength(1));
      expect(catalog.groups.single.instances.single.count, 2);
    });

    test('leaks that tie keep the order they were found in, however many there are', () {
      // Dart's sort is only stable for short lists, so a long one is what shows it.
      scan('a', [for (var i = 0; i < 80; i++) _report(signature: 'leak$i', reason: 'leak $i')]);

      expect(catalog.groups.map((group) => group.reason), [for (var i = 0; i < 80; i++) 'leak $i']);
    });

    group('when reports with different signatures are one leak', () {
      late LeakCatalog grouped;

      setUp(() {
        grouped = LeakCatalog(now: () => now, groupKey: (report) => report.reason);
      });

      tearDown(() => grouped.dispose());

      void found(List<LeakReport> leaks) {
        grouped.onEvent(HeapDumpEvent('x', dump: _dump(1), duration: Duration.zero, reason: 'r'));
        grouped.onEvent(_succeeded('x', leaks));
      }

      test('each signature is an instance of the leak, and the leak counts them all', () {
        found([
          _report(signature: 'created-at-42', reason: 'a page was disposed', count: 2, creationSite: _initState),
          _report(
            signature: 'created-at-99',
            reason: 'a page was disposed',
            count: 3,
            creationSite: const CreationSite(uri: 'package:app/other.dart', line: 99),
          ),
        ]);

        final group = grouped.groups.single;
        expect(group.instances.map((instance) => instance.signature), ['created-at-42', 'created-at-99']);
        expect(group.instances.map((instance) => instance.count), [2, 3]);
        expect(group.count, 5);
        expect(group.instances.map((instance) => instance.creationSite?.line), [42, 99]);
      });

      test('a later scan adds to the instance it matches, and to no other', () {
        found([_report(signature: 'one', reason: 'same', count: 1), _report(signature: 'two', reason: 'same', count: 1)]);
        now = now.add(const Duration(minutes: 2));

        found([_report(signature: 'two', reason: 'same', count: 4)]);

        final group = grouped.groups.single;
        expect(group.instances.map((instance) => instance.count), [1, 5]);
        expect(group.count, 6);
        expect(group.instances.first.lastSeen, DateTime(2026, 1, 1, 12));
        expect(group.instances.last.lastSeen, DateTime(2026, 1, 1, 12, 2));
        expect(group.lastSeen, DateTime(2026, 1, 1, 12, 2));
      });

      test('a new signature of a leak that is already known is not a new leak', () {
        found([_report(signature: 'one', reason: 'same')]);
        grouped.markRead(grouped.groups.single.id);

        found([_report(signature: 'two', reason: 'same')]);

        expect(grouped.groups.single.isUnread, isFalse);
        expect(grouped.scans.first.newCount, 0);
      });

      test('resources are still kept apart', () {
        found([_report(signature: 'one', reason: 'same')]);
        grouped.addResourceLeak(_report(signature: 'two', reason: 'same', confidence: LeakConfidence.resourceNeverClosed));

        expect(grouped.groups, hasLength(2));
      });
    });

    test('the sort is by what was found, not by when the screen asked', () {
      scan('a', [_report(signature: 'a', reason: 'a', count: 1)]);
      final before = catalog.groups;

      scan('b', [_report(signature: 'b', reason: 'b', count: 4)]);

      expect(before.map((group) => group.reason), ['a']);
      expect(catalog.groups.map((group) => group.reason), ['b', 'a']);
    });

    test('the list it gives cannot be changed', () {
      scan('a', [_report()]);

      expect(() => catalog.groups.clear(), throwsUnsupportedError);
      expect(() => catalog.groups.single.instances.clear(), throwsUnsupportedError);
      expect(() => catalog.scans.clear(), throwsUnsupportedError);
    });

    test('a leak is found by its id', () {
      scan('a', [_report()]);
      final group = catalog.groups.single;

      expect(catalog.groupById(group.id), same(group));
      expect(catalog.groupById('nothing'), isNull);
    });
  });

  group('the creation site, and the reason it is missing', () {
    test('are kept with the leak', () {
      scan('a', [
        _report(signature: 'created', creationSite: _initState),
        _report(signature: 'watched', creationSite: null, watchSite: const CreationSite(uri: 'package:app/p.dart', line: 7)),
        _report(signature: 'unknown', creationSite: null, gap: CreationSiteGap.onlyFrameworkFrames, classSite: const CreationSite(uri: 'package:app/p.dart', member: '_S', line: 3)),
      ]);

      final bySignature = {for (final group in catalog.groups) group.instances.single.signature: group.instances.single};
      expect(bySignature['created']!.creationSite, _initState);
      expect(bySignature['created']!.creationSiteGap, isNull);
      expect(bySignature['watched']!.watchSite!.line, 7);
      expect(bySignature['unknown']!.creationSiteGap, CreationSiteGap.onlyFrameworkFrames);
      expect(bySignature['unknown']!.classSite!.line, 3);
    });

    test('a later scan that finds the class declaration adds it', () {
      scan('a', [_report(creationSite: null, gap: CreationSiteGap.onlyFrameworkFrames, pathGap: RetainingPathGap.lookupLimitReached)]);
      expect(catalog.groups.single.instances.single.classSite, isNull);

      scan(
        'b',
        [
          _report(
            creationSite: null,
            gap: CreationSiteGap.onlyFrameworkFrames,
            classSite: const CreationSite(uri: 'package:app/p.dart', member: '_S', line: 3),
            path: const RetainingPathInfo(gcRootType: 'user global', hops: ['_S']),
          ),
        ],
      );

      final instance = catalog.groups.single.instances.single;
      expect(instance.classSite!.line, 3);
      expect(instance.retainingPath, isNotNull);
      expect(instance.pathGap, isNull, reason: 'a path is there now');
    });

    test('a later scan that has no path leaves the earlier path in place', () {
      const path = RetainingPathInfo(gcRootType: 'user global', hops: ['_Page', 'Holder.list']);
      scan('a', [_report(path: path)]);

      scan('b', [_report(pathGap: RetainingPathGap.lookupLimitReached)]);

      final instance = catalog.groups.single.instances.single;
      expect(instance.retainingPath, same(path));
      expect(instance.pathGap, isNull);
    });

    test('why there is no path is kept until one is found', () {
      scan('a', [_report(pathGap: RetainingPathGap.noVmService)]);
      scan('b', [_report()]);

      expect(catalog.groups.single.instances.single.pathGap, RetainingPathGap.noVmService);
    });
  });

  group('resources that were never closed', () {
    test('are a leak of their own kind, counted each time one is collected', () {
      final stack = StackTrace.current;
      catalog.addResourceLeak(
        _report(
          type: _Other,
          reason: 'PageFour.controller',
          signature: '_Other|resourceNeverClosed|PageFour.controller',
          confidence: LeakConfidence.resourceNeverClosed,
          acquiredAt: stack,
        ),
      );
      catalog.addResourceLeak(
        _report(
          type: _Other,
          reason: 'PageFour.controller',
          signature: '_Other|resourceNeverClosed|PageFour.controller',
          confidence: LeakConfidence.resourceNeverClosed,
          acquiredAt: stack,
        ),
      );

      final group = catalog.groups.single;
      expect(group.kind, LeakKind.resource);
      expect(group.count, 2);
      expect(group.isUnread, isTrue);
      expect(group.instances.single.acquiredAt, same(stack));
      expect(catalog.scans, isEmpty, reason: 'a resource is found by the collector, not by a scan');
    });

    test('are kept apart from retained objects with the same signature', () {
      scan('a', [_report(signature: 'same')]);
      catalog.addResourceLeak(_report(signature: 'same', confidence: LeakConfidence.resourceNeverClosed));

      expect(catalog.groups.map((group) => group.kind), unorderedEquals([LeakKind.retained, LeakKind.resource]));
    });
  });

  group('what has been read', () {
    test('a leak is unread until it is opened, and being found again does not make it unread again', () {
      scan('a', [_report()]);
      final id = catalog.groups.single.id;

      catalog.markRead(id);
      expect(catalog.groups.single.isUnread, isFalse);
      expect(catalog.unreadCount, 0);

      scan('b', [_report()]);
      expect(catalog.groups.single.isUnread, isFalse);
    });

    test('a new leak next to an old one is the only one unread', () {
      scan('a', [_report(signature: 'old', reason: 'old')]);
      catalog.markRead(catalog.groups.single.id);

      scan('b', [_report(signature: 'new', reason: 'new')]);

      expect({for (final group in catalog.groups) group.reason: group.isUnread}, {'old': false, 'new': true});
      expect(catalog.unreadCount, 1);
    });

    test('marking read tells the listeners once, and marking what is read or unknown tells nobody', () {
      scan('a', [_report()]);
      final id = catalog.groups.single.id;
      notifications = 0;

      catalog.markRead(id);
      catalog.markRead(id);
      catalog.markRead('nothing');

      expect(notifications, 1);
    });
  });

  group('clearing', () {
    test('forgets every leak and every scan, and tells the listeners once', () {
      scan('a', [_report()]);
      notifications = 0;

      catalog.clear();

      expect(catalog.groups, isEmpty);
      expect(catalog.scans, isEmpty);
      expect(catalog.objectCount, 0);
      expect(notifications, 1);
    });

    test('has nothing to tell when there is nothing', () {
      catalog.clear();

      expect(notifications, 0);
    });

    test('a leak found after it is a new leak again', () {
      scan('a', [_report()]);
      catalog.markRead(catalog.groups.single.id);
      catalog.clear();

      scan('b', [_report()]);

      expect(catalog.groups.single.isUnread, isTrue);
      expect(catalog.groups.single.count, 1);
    });
  });

  group('scans', () {
    test('a dumped heap starts a scan, which says how many objects were in it and why it was dumped', () {
      catalog.onEvent(const DumpingHeapEvent('prev'));
      expect(catalog.isDumping, isTrue);

      catalog.onEvent(_dumped('a', held: 7, reason: 'user request'));

      expect(catalog.isDumping, isFalse);
      final scan = catalog.scans.single;
      expect(scan.id, 'a');
      expect(scan.status, ScanStatus.running);
      expect(scan.heldCount, 7);
      expect(scan.trigger, 'user request');
      expect(scan.time, now);
      expect(catalog.runningScan, same(scan));
    });

    test('progress events say which step the analysis is on', () {
      catalog.onEvent(_dumped('a'));

      catalog.onEvent(const HeapAnalysisProgressEvent('a', step: AnalysisStep.findingPathsToRetainedObjects, progressPercent: 0.3));

      final scan = catalog.scans.single;
      expect(scan.step, AnalysisStep.findingPathsToRetainedObjects);
      expect(scan.progress, 0.3);
      expect(scan.status, ScanStatus.running);
    });

    test('a finished analysis completes the scan with the leaks it found, and which were new', () {
      scan('a', [_report(signature: 'old', reason: 'old', count: 2)]);
      now = now.add(const Duration(minutes: 5));

      scan('b', [_report(signature: 'old', reason: 'old', count: 1), _report(signature: 'new', reason: 'new', count: 4)], held: 5, released: 2);

      final second = catalog.scans.first;
      expect(second.id, 'b');
      expect(second.status, ScanStatus.succeeded);
      expect(second.heldCount, 5);
      expect(second.releasedCount, 2);
      expect(second.analysisDuration, const Duration(milliseconds: 30));
      expect(second.progress, 1);
      expect(second.leaks.map((leak) => (leak.reason, leak.count, leak.isNew)), [('old', 1, false), ('new', 4, true)]);
      expect(second.newCount, 1);
      expect(catalog.scans.last.newCount, 1, reason: 'the first scan found its leak first');
      expect(catalog.runningScan, isNull);
    });

    test('a scan lists where each of its leaks came from', () {
      scan('a', [_report(creationSite: _initState), _report(signature: 'framework', creationSite: null, gap: CreationSiteGap.onlyFrameworkFrames)]);

      final leaks = catalog.scans.single.leaks;
      expect(leaks.first.creationSite, _initState);
      expect(leaks.last.creationSiteGap, CreationSiteGap.onlyFrameworkFrames);
      expect(leaks.first.groupId, catalog.groups.firstWhere((group) => group.instances.single.creationSite != null).id);
    });

    test('a failed analysis fails the scan, with what went wrong', () {
      catalog.onEvent(_dumped('a'));

      catalog.onEvent(_analysisFailed('a', StateError('the VM went away')));

      final scan = catalog.scans.single;
      expect(scan.status, ScanStatus.failed);
      expect(scan.failure, contains('the VM went away'));
      expect(catalog.groups, isEmpty);
    });

    test('a heap that could not be dumped is a scan of its own, that says it will be tried again', () {
      catalog.onEvent(const DumpingHeapEvent('a'));

      catalog.onEvent(HeapDumpFailedEvent('a', exception: StateError('no space'), willRetryLater: true));

      expect(catalog.isDumping, isFalse);
      final scan = catalog.scans.single;
      expect(scan.status, ScanStatus.failed);
      expect(scan.failure, contains('no space'));
      expect(scan.willRetry, isTrue);
      expect(scan.heldCount, 0);
    });

    test('the events of the next dump carry the id of the last one, and must not touch its scan', () {
      scan('a', [_report()]);
      final first = catalog.scans.single;

      // What the trigger really does: the chain's id is the id of the dump
      // before it until the next heap is dumped.
      catalog.onEvent(const DumpingHeapEvent('a'));
      catalog.onEvent(HeapDumpFailedEvent('a', exception: StateError('no space'), willRetryLater: true));

      expect(catalog.scans, hasLength(2));
      expect(catalog.scans.last, same(first), reason: 'the scan before is as it was');
      expect(catalog.scans.last.status, ScanStatus.succeeded);
      expect(catalog.scans.first.status, ScanStatus.failed);
      expect(catalog.scans.first.id, isNot('a'));
    });

    test('two failed dumps in a row are two scans', () {
      catalog.onEvent(HeapDumpFailedEvent('a', exception: StateError('1'), willRetryLater: true));
      catalog.onEvent(HeapDumpFailedEvent('a', exception: StateError('2'), willRetryLater: true));

      expect(catalog.scans, hasLength(2));
      expect(catalog.scans.map((scan) => scan.id).toSet(), hasLength(2));
    });

    test('a dump after a failure reuses the failed id and is a scan of its own', () {
      catalog.onEvent(HeapDumpFailedEvent('a', exception: StateError('no space'), willRetryLater: true));

      scan('b', [_report()]);

      expect(catalog.scans.map((scan) => scan.status), [ScanStatus.succeeded, ScanStatus.failed]);
    });

    test('the latest scan is first', () {
      scan('a', [_report()]);
      now = now.add(const Duration(minutes: 1));
      scan('b', [_report()]);

      expect(catalog.scans.map((scan) => scan.id), ['b', 'a']);
    });

    test('only the latest scans are kept', () {
      final small = LeakCatalog(now: () => now, maxScans: 3);
      for (var i = 0; i < 5; i++) {
        small.onEvent(_dumped('scan$i'));
      }

      expect(small.scans.map((scan) => scan.id), ['scan4', 'scan3', 'scan2']);
      small.dispose();
    });

    test('an analysis whose dump was never seen is still listed', () {
      catalog.onEvent(_succeeded('late', [_report()], held: 4, released: 1));

      final scan = catalog.scans.single;
      expect(scan.id, 'late');
      expect(scan.status, ScanStatus.succeeded);
      expect(scan.heldCount, 4);
      expect(scan.releasedCount, 1);
      expect(scan.leaks, hasLength(1));
      expect(catalog.groups, hasLength(1));
    });

    test('progress for a scan nobody knows is ignored', () {
      notifications = 0;

      catalog.onEvent(const HeapAnalysisProgressEvent('nothing', step: AnalysisStep.buildingLeakTraces, progressPercent: 0.8));
      catalog.onEvent(_analysisFailed('nothing', StateError('x')));

      expect(catalog.scans, isEmpty);
      expect(notifications, 0);
    });

    test('whether the heap is being dumped is known from the first event to the dump or its failure', () {
      expect(catalog.isDumping, isFalse);
      catalog.onEvent(const DumpingHeapEvent('a'));
      expect(catalog.isDumping, isTrue);
      catalog.onEvent(HeapDumpFailedEvent('a', exception: StateError('x'), willRetryLater: false));
      expect(catalog.isDumping, isFalse);
      catalog.onEvent(const DumpingHeapEvent('a'));
      catalog.onEvent(_dumped('b'));
      expect(catalog.isDumping, isFalse);
    });
  });

  group('telling the listeners', () {
    test('every change is told once, and a repeat of the dumping event is no change', () {
      catalog.onEvent(const DumpingHeapEvent('a'));
      catalog.onEvent(const DumpingHeapEvent('a'));
      expect(notifications, 1);

      catalog.onEvent(_dumped('a'));
      expect(notifications, 2);

      catalog.onEvent(const HeapAnalysisProgressEvent('a', step: AnalysisStep.buildingLeakTraces, progressPercent: 0.8));
      expect(notifications, 3);

      catalog.onEvent(_succeeded('a', [_report()]));
      expect(notifications, 4);
    });

    test('a leak that is resource leak is told as it is found', () {
      catalog.addResourceLeak(_report(confidence: LeakConfidence.resourceNeverClosed));

      expect(notifications, 1);
    });

    test('once disposed, what the engine still sends is ignored instead of throwing', () {
      catalog.dispose();

      expect(() {
        catalog.onEvent(const DumpingHeapEvent('a'));
        catalog.onEvent(_dumped('a'));
        catalog.addResourceLeak(_report(confidence: LeakConfidence.resourceNeverClosed));
        catalog.markRead('x');
        catalog.clear();
      }, returnsNormally);
      expect(catalog.dispose, returnsNormally, reason: 'the engine disposes it once however many times it is disposed');
    });
  });
}
