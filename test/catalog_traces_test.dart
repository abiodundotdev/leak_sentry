import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/heap_analysis.dart';
import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/analysis/node_status.dart';
import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/retaining_element.dart';

class _Page {}

class _Controller {}

/// A trace of a `Registry` that holds the leaked object in a variable, with [fingerprint].
LeakTrace _trace(String? fingerprint, {String holder = 'Registry', String variable = 'pages', String library = 'package:app/registry.dart'}) =>
    LeakTrace(
      gcRootType: 'user global',
      fingerprint: fingerprint,
      nodes: [
        TraceNode(
          kind: TraceNodeKind.staticHolder,
          name: holder,
          library: library,
          status: NodeStatus.inUse,
          reference: TraceReference(
            kind: TraceReferenceKind.staticVariable,
            name: '.$variable',
            genericName: variable,
            isSuspect: fingerprint != null,
          ),
        ),
        const TraceNode(kind: TraceNodeKind.instance, name: 'Leaked', status: NodeStatus.shouldBeGone),
      ],
    );

LeakReport _report(
  String signature, {
  Type type = _Page,
  int count = 1,
  LeakTrace? trace,
  RetainingPathInfo? path,
  LeakConfidence confidence = LeakConfidence.retainedAfterGc,
}) => LeakReport(
  type: type,
  reason: 'was disposed',
  firstObservedAt: DateTime(2026),
  detectedAt: DateTime(2026),
  confidence: confidence,
  signature: signature,
  occurrenceCount: count,
  trace: trace,
  retainingPath: path,
);

HeapAnalysisSucceededEvent _succeeded(String id, List<LeakReport> leaks) => HeapAnalysisSucceededEvent(
  id,
  heapAnalysis: HeapAnalysisSuccess(
    dump: const RetainedObjectsDump(objects: [], dumpUptime: Duration(seconds: 6), isolateId: 'isolates/1'),
    analysisDuration: const Duration(milliseconds: 30),
    leaks: leaks,
    unreachableObjectCount: 0,
  ),
  newLeakSignatures: const {},
);

void main() {
  late DateTime now;
  late LeakCatalog catalog;

  setUp(() {
    now = DateTime(2026, 1, 1, 12);
    catalog = LeakCatalog(now: () => now);
  });

  tearDown(() => catalog.dispose());

  void scan(String id, List<LeakReport> leaks) => catalog.onEvent(_succeeded(id, leaks));

  group('which leak a report is', () {
    test('what is held by the same likely cause is one leak, whatever it is', () {
      scan('a', [
        _report('page', trace: _trace('registry.pages'), count: 2),
        _report('controller', type: _Controller, trace: _trace('registry.pages'), count: 3),
      ]);

      final group = catalog.groups.single;
      expect(group.instances.map((instance) => instance.signature), ['page', 'controller']);
      expect(group.count, 5);
      expect(group.leakedTypes, ['_Page', '_Controller']);
      expect(catalog.leakCount, 1);
      expect(catalog.objectCount, 5);
    });

    test('says each type once, however many places it was created at', () {
      scan('a', [
        _report('page-at-42', trace: _trace('registry.pages')),
        _report('page-at-77', trace: _trace('registry.pages')),
        _report('controller', type: _Controller, trace: _trace('registry.pages')),
      ]);

      expect(catalog.groups.single.instances, hasLength(3));
      expect(catalog.groups.single.leakedTypes, ['_Page', '_Controller']);
    });

    test('what is held by different likely causes is different leaks, even of the same signature', () {
      scan('a', [
        _report('page', trace: _trace('registry.pages')),
        _report('page', trace: _trace('cache.pages')),
      ]);

      expect(catalog.groups, hasLength(2));
    });

    test('a report with no fingerprint is a leak of its signature, as when nothing is traced', () {
      scan('a', [_report('one'), _report('two'), _report('one', count: 4)]);

      expect(catalog.groups, hasLength(2));
      expect(catalog.groups.map((group) => group.count).toList()..sort(), [1, 5]);
    });

    test('a report whose trace has no fingerprint is a leak of its signature too', () {
      scan('a', [_report('one', trace: _trace(null)), _report('two', trace: _trace(null))]);

      expect(catalog.groups, hasLength(2));
    });

    test('a fingerprint is not mistaken for a signature that says the same', () {
      scan('a', [_report('registry.pages'), _report('other', trace: _trace('registry.pages'))]);

      expect(catalog.groups, hasLength(2));
    });

    test('is found again by a later scan with another signature, and is still one leak', () {
      scan('a', [_report('page-at-42', trace: _trace('registry.pages'))]);
      now = now.add(const Duration(minutes: 5));
      scan('b', [_report('page-at-77', trace: _trace('registry.pages'))]);

      final group = catalog.groups.single;
      expect(group.instances, hasLength(2));
      expect(group.firstSeen, DateTime(2026, 1, 1, 12));
      expect(group.lastSeen, DateTime(2026, 1, 1, 12, 5));
    });

    test('only the first of what a scan finds is new, and the scan says how many leaks that is', () {
      catalog.onEvent(_succeeded('a', [
        _report('page', trace: _trace('registry.pages')),
        _report('controller', type: _Controller, trace: _trace('registry.pages')),
        _report('other', trace: _trace('cache.pages')),
      ]));

      final record = catalog.scans.single;
      expect(record.leaks, hasLength(3), reason: 'one row for each kind of object found');
      expect(record.leakCount, 2, reason: 'held two ways');
      expect(record.newCount, 2);
      expect(record.leaks.map((leak) => leak.isNew), [true, true, true], reason: 'what is held the same way is new together');
      expect(record.leaks[0].groupId, record.leaks[1].groupId);
      expect(record.leaks[0].groupId, isNot(record.leaks[2].groupId));
    });

    test('what a later scan finds of a leak that is not new is not new, however it is held', () {
      scan('a', [_report('page', trace: _trace('registry.pages'))]);
      scan('b', [
        _report('controller', type: _Controller, trace: _trace('registry.pages')),
        _report('other', trace: _trace('cache.pages')),
      ]);

      final latest = catalog.scans.first;
      expect(latest.leaks.map((leak) => leak.isNew), [false, true]);
      expect(latest.newCount, 1);
      expect(latest.leakCount, 2);
    });

    test('what is retained is told by its signature, whatever place the report names: the signature has the place', () {
      LeakReport retainedAt(int line) => LeakReport(
        type: _Page,
        reason: 'was disposed',
        firstObservedAt: DateTime(2026),
        detectedAt: DateTime(2026),
        confidence: LeakConfidence.retainedAfterGc,
        signature: 'same signature',
        creationSite: CreationSite(uri: 'package:app/page.dart', line: line),
      );

      scan('a', [retainedAt(10), retainedAt(20)]);

      expect(catalog.groups, hasLength(1));
      expect(catalog.groups.single.instances, hasLength(1));
      expect(catalog.groups.single.count, 2);
    });

    test('resources with one label acquired in different places are different leaks, each with its place', () {
      LeakReport resource(int line) => LeakReport(
        type: _Page,
        reason: 'StreamController<int>',
        firstObservedAt: DateTime(2026),
        detectedAt: DateTime(2026),
        confidence: LeakConfidence.resourceNeverClosed,
        signature: 'StreamController<int>|resourceNeverClosed|StreamController<int>',
        creationSite: CreationSite(uri: 'package:app/page.dart', member: 'initState', line: line),
      );

      catalog.addResourceLeak(resource(10));
      catalog.addResourceLeak(resource(20));
      catalog.addResourceLeak(resource(10));

      expect(catalog.groups, hasLength(2));
      expect(catalog.groups.map((group) => group.count).toList()..sort(), [1, 2]);
      expect({for (final group in catalog.groups) group.instances.single.creationSite!.line}, {10, 20});
    });

    test('a resource without a place is one leak of its signature', () {
      LeakReport resource() => LeakReport(
        type: _Page,
        reason: 'label',
        firstObservedAt: DateTime(2026),
        detectedAt: DateTime(2026),
        confidence: LeakConfidence.resourceNeverClosed,
        signature: 'sig',
      );

      catalog.addResourceLeak(resource());
      catalog.addResourceLeak(resource());

      expect(catalog.groups.single.count, 2);
    });

    test('a resource is a leak of its own, whatever a fingerprint says', () {
      catalog.addResourceLeak(_report('res', confidence: LeakConfidence.resourceNeverClosed, trace: _trace('registry.pages')));
      scan('a', [_report('page', trace: _trace('registry.pages'))]);

      expect(catalog.groups, hasLength(2));
      expect(catalog.groups.map((group) => group.kind), containsAll([LeakKind.resource, LeakKind.retained]));
    });
  });

  group('what a leak is called', () {
    test('is its likely cause, and the type of what leaked when there is none', () {
      scan('a', [_report('page', trace: _trace('registry.pages')), _report('no trace', type: _Controller)]);

      expect(catalog.groups.map((group) => group.title).toSet(), {'Registry.pages', '_Controller'});
      expect(catalog.groups.firstWhere((group) => group.title == 'Registry.pages').cause, 'Registry.pages');
      expect(catalog.groups.firstWhere((group) => group.title == '_Controller').cause, isNull);
    });

    test('is the type of what leaked when the path is known and no cause is, as for a path nothing worked out', () {
      scan('a', [
        _report(
          'page',
          path: const RetainingPathInfo(
            gcRootType: 'user global',
            hops: ['Leaked', 'Registry.pages'],
            elements: [
              RetainingElement(kind: RetainingElementKind.instance, className: 'Leaked'),
              RetainingElement(kind: RetainingElementKind.staticField, className: 'Registry', field: 'pages'),
            ],
          ),
        ),
      ]);

      final group = catalog.groups.single;
      expect(group.title, '_Page');
      expect(group.instances.single.trace, isNotNull, reason: 'the steps are there to be shown');
      expect(group.instances.single.trace!.fingerprint, isNull);
      expect(group.instances.single.trace!.nodes.map((node) => node.status), everyElement(isNull));
    });

    test('is the label of a resource, which no trace names', () {
      catalog.addResourceLeak(_report('res', confidence: LeakConfidence.resourceNeverClosed));

      expect(catalog.groups.single.title, 'was disposed');
      expect(catalog.groups.single.cause, isNull);
    });

    test('follows the freshest trace: a later scan that knows more renames it', () {
      scan('a', [_report('page', trace: _trace('registry.pages', holder: 'Registry'))]);
      now = now.add(const Duration(minutes: 1));
      scan('b', [_report('page', trace: _trace('registry.pages', holder: 'PageRegistry'))]);

      expect(catalog.groups.single.title, 'PageRegistry.pages');
    });

    test('keeps the last trace of what is found again by a scan that has none', () {
      // Grouped by what it says, as an app can ask: the second report has no fingerprint to group it by.
      final byReason = LeakCatalog(now: () => now, groupKey: (report) => report.reason);
      addTearDown(byReason.dispose);

      byReason.onEvent(_succeeded('a', [_report('page', trace: _trace('registry.pages'))]));
      now = now.add(const Duration(minutes: 1));
      byReason.onEvent(_succeeded('b', [_report('page')]));

      final group = byReason.groups.single;
      expect(group.instances.single.count, 2);
      expect(group.instances.single.trace, isNotNull);
      expect(group.title, 'Registry.pages');
    });

    test('of several kinds of object held the same way is the cause of the one seen last', () {
      scan('a', [_report('page', trace: _trace('registry.pages', holder: 'Old'))]);
      now = now.add(const Duration(minutes: 2));
      scan('b', [_report('controller', type: _Controller, trace: _trace('registry.pages', holder: 'New'))]);

      expect(catalog.groups.single.title, 'New.pages');
    });

    test('of kinds seen together is the cause of the one found first', () {
      scan('a', [
        _report('page', trace: _trace('registry.pages', holder: 'First')),
        _report('controller', type: _Controller, trace: _trace('registry.pages', holder: 'Second')),
      ]);

      expect(catalog.groups.single.title, 'First.pages');
    });
  });

  group('the path to show', () {
    test('of instances seen together is the one found first', () {
      scan('a', [
        _report('page', trace: _trace('registry.pages', holder: 'First')),
        _report('controller', type: _Controller, trace: _trace('registry.pages', holder: 'Second')),
      ]);

      final group = catalog.groups.single;
      expect(group.latestTraced!.signature, 'page');
      expect(group.latest.signature, 'page');
    });

    test('is the one of the instance seen last that has one', () {
      scan('a', [_report('page', trace: _trace('registry.pages', holder: 'Old'))]);
      now = now.add(const Duration(minutes: 2));
      scan('b', [_report('controller', type: _Controller, trace: _trace('registry.pages', holder: 'New'))]);
      now = now.add(const Duration(minutes: 2));
      scan('c', [_report('page', trace: _trace('registry.pages', holder: 'Old'))]);

      final group = catalog.groups.single;

      expect(group.latestTraced!.signature, 'page');
      expect(group.latestTraced!.trace!.nodes.first.name, 'Old');
    });

    test('is none when no instance has a path', () {
      scan('a', [_report('page')]);

      expect(catalog.groups.single.latestTraced, isNull);
    });
  });

  group('a leak held by LeakSentry itself', () {
    test('is told when any one of its instances is', () {
      scan('a', [
        _report('mine', trace: _trace('registry.pages', library: 'package:leak_sentry/ui/thing.dart')),
        _report('yours', type: _Controller, trace: _trace('registry.pages')),
      ]);

      expect(catalog.groups.single.instances, hasLength(2));
      expect(catalog.groups.single.isInternal, isTrue);
    });

    test('is told, because that is a bug in LeakSentry', () {
      scan('a', [
        _report('mine', trace: _trace('leak_sentry.thing', library: 'package:leak_sentry/ui/thing.dart')),
        _report('yours', trace: _trace('registry.pages')),
      ]);

      final byTitle = {for (final group in catalog.groups) group.id: group.isInternal};
      expect(byTitle.values.where((internal) => internal), hasLength(1));
      expect(byTitle.values.where((internal) => !internal), hasLength(1));
    });
  });
}
