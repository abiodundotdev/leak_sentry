import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/heap_analysis.dart';
import 'package:leak_sentry/analysis/heap_analyzer.dart';
import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/analysis/node_status.dart';
import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';
import 'package:leak_sentry/models/field_facts.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/leak_sentry_stats.dart';
import 'package:leak_sentry/models/retaining_element.dart';
import 'package:leak_sentry/object_watcher/keyed_weak_reference.dart';

import 'fakes/fake_vm_bridge.dart';
import 'helpers/capture_log.dart';

class _Page {}

RetainedObjectSnapshot _snapshot(
  String key, {
  String description = '_Page received State#dispose() callback',
  String? vmObjectId = 'objects/leaked',
  bool collected = false,
}) => RetainedObjectSnapshot(
  key: key,
  description: description,
  type: _Page,
  identityHash: key.hashCode,
  watchUptime: Duration.zero,
  retainedUptime: const Duration(seconds: 5),
  watchedAt: DateTime(2026, 1, 1),
  vmObjectIdResolver: () => collected ? null : vmObjectId,
  collectedProbe: () => collected,
);

RetainedObjectsDump _dump(List<RetainedObjectSnapshot> objects, {String? isolateId = 'isolates/1'}) =>
    RetainedObjectsDump(objects: objects, dumpUptime: const Duration(seconds: 6), isolateId: isolateId);

/// `Registry.holders` holds a `Holder`, which holds the leaked `_Page` in its `page`.
/// The VM lists it the leaked object first.
RetainingPathInfo _path({int? holderHash}) => RetainingPathInfo(
  gcRootType: 'user global',
  hops: const ['_Page', 'Holder.page', 'Registry.holders'],
  elements: [
    const RetainingElement(
      kind: RetainingElementKind.instance,
      className: '_Page',
      libraryUri: 'package:app/page.dart',
      objectId: 'objects/leaked',
    ),
    RetainingElement(
      kind: RetainingElementKind.instance,
      className: 'Holder',
      libraryUri: 'package:app/holder.dart',
      identityHash: holderHash,
      objectId: 'objects/holder',
      field: 'page',
    ),
    const RetainingElement(
      kind: RetainingElementKind.staticField,
      className: 'Registry',
      libraryUri: 'package:app/registry.dart',
      field: 'holders',
    ),
  ],
);

const FieldFacts _stateOnScreen = FieldFacts(declaringClasses: {'State'}, values: {'State._element': 'StatefulElement'});
const FieldFacts _stateDisposed = FieldFacts(declaringClasses: {'State'}, values: {'State._element': 'null'});

/// Facts that fail when they are asked anything, to be a bug in what reads them.
class _ExplodingFacts extends FieldFacts {
  const _ExplodingFacts();

  @override
  bool declares(String className) => throw StateError('boom');
}

String _statuses(LeakTrace trace) => [
  for (final node in trace.nodes)
    switch (node.status!) {
      NodeStatus.inUse => 'E',
      NodeStatus.shouldBeGone => 'S',
      NodeStatus.unclear => 'U',
    },
].join();

void main() {
  late FakeVmBridge vm;
  late LeakSentryConfig config;
  late RetainedSetHeapAnalyzer analyzer;

  setUp(() {
    vm = FakeVmBridge()..path = _path();
    config = const LeakSentryConfig();
    analyzer = RetainedSetHeapAnalyzer(vm: vm, config: () => config, stats: LeakSentryStats());
  });

  Future<List<LeakReport>> leaks(RetainedObjectsDump dump, {AnalysisProgressListener? onProgress}) async {
    final analysis = await analyzer.analyze(dump, onProgress: onProgress);
    expect(analysis, isA<HeapAnalysisSuccess>());
    return (analysis as HeapAnalysisSuccess).leaks;
  }

  Future<LeakTrace?> traceOfOne() async => (await leaks(_dump([_snapshot('a')]))).single.trace;

  group('the trace of a leak', () {
    test('is its retaining path worked out: what each step is, the likely causes, and a fingerprint', () async {
      final leak = (await leaks(_dump([_snapshot('a')]))).single;

      final trace = leak.trace!;
      expect(_statuses(trace), 'EUS');
      expect(trace.title, 'Registry.holders');
      expect(trace.fingerprint, 'package:app/registry.dart:Registry:holders|package:app/holder.dart:Holder:page');
      expect(trace.nodes.last.note, 'Expected to be gone: _Page received State#dispose() callback');
      expect(leak.retainingPath, same(vm.path), reason: 'the path itself stays as the VM said it');
    });

    test('is made for the representative of each leak, from its own path', () async {
      vm.pathsById['objects/other'] = const RetainingPathInfo(
        gcRootType: 'user global',
        hops: ['_Page', 'Cache.page'],
        elements: [
          RetainingElement(kind: RetainingElementKind.instance, className: '_Page', libraryUri: 'package:app/page.dart'),
          RetainingElement(
            kind: RetainingElementKind.staticField,
            className: 'Cache',
            libraryUri: 'package:app/cache.dart',
            field: 'page',
          ),
        ],
      );

      final found = await leaks(
        _dump([
          _snapshot('a'),
          _snapshot('b', description: 'another reason', vmObjectId: 'objects/other'),
        ]),
      );

      expect(found.map((leak) => leak.trace!.title), ['Registry.holders', 'Cache.page']);
    });

    test('is not made for a path that has no steps to work out, and nothing is asked of the VM for it', () async {
      vm.path = const RetainingPathInfo(gcRootType: 'user global', hops: ['_Page', 'Holder.page']);

      final leak = (await leaks(_dump([_snapshot('a')]))).single;

      expect(leak.trace, isNull);
      expect(leak.retainingPath, isNotNull);
      expect(vm.fieldReads, isEmpty);
    });

    test('is not made when there is no path, whatever the reason', () async {
      final cases = <String, Future<LeakReport> Function()>{
        'paths are turned off': () async {
          config = const LeakSentryConfig(enableRetainingPathAnalysis: false);
          return (await leaks(_dump([_snapshot('a')]))).single;
        },
        'the dump has no isolate': () async => (await leaks(_dump([_snapshot('a')], isolateId: null))).single,
        'the object has no id': () async => (await leaks(_dump([_snapshot('a', vmObjectId: null)]))).single,
        'the lookup limit is reached': () async {
          config = const LeakSentryConfig(maxRetainingPathLookups: 0);
          return (await leaks(_dump([_snapshot('a')]))).single;
        },
        'the VM gives no answer': () async {
          vm.path = null;
          return (await leaks(_dump([_snapshot('a')]))).single;
        },
      };

      for (final entry in cases.entries) {
        config = const LeakSentryConfig();
        vm.path = _path();
        final leak = await entry.value();

        expect(leak.trace, isNull, reason: entry.key);
        expect(leak.retainingPath, isNull, reason: entry.key);
      }
      expect(vm.fieldReads, isEmpty);
    });
  });

  group('the fields of the objects on the path', () {
    test('tell a State that was disposed, and what it holds should be gone too', () async {
      vm.fieldFacts['objects/holder'] = _stateDisposed;

      final trace = (await traceOfOne())!;

      expect(_statuses(trace), 'ESS');
      expect(trace.nodes[1].note, 'A State that was disposed.');
      expect(trace.title, 'Registry.holders', reason: 'the cause is where something that is in use holds it');
    });

    test('tell a State that is on screen: what holds it is in use, and the cause is its reference', () async {
      vm.fieldFacts['objects/holder'] = _stateOnScreen;

      final trace = (await traceOfOne())!;

      expect(_statuses(trace), 'EES');
      expect(trace.title, 'Holder.page');
    });

    test('are what the fingerprint is not made from: the same leak is the same leak whatever the VM said', () async {
      final without = (await traceOfOne())!;
      vm.fieldFacts['objects/holder'] = _stateDisposed;
      final disposed = (await traceOfOne())!;
      vm.fieldFacts['objects/holder'] = _stateOnScreen;
      final onScreen = (await traceOfOne())!;

      expect(disposed.fingerprint, without.fingerprint);
      expect(onScreen.fingerprint, without.fingerprint);
      expect({_statuses(without), _statuses(disposed), _statuses(onScreen)}, hasLength(3), reason: 'but what is shown differs');
    });

    test('are asked about nearest the leak first, and only for steps that can be told by them', () async {
      vm.path = const RetainingPathInfo(
        gcRootType: 'user global',
        hops: ['leaked', 'list', 'closure', 'timer', 'holder', 'static'],
        elements: [
          RetainingElement(kind: RetainingElementKind.instance, className: '_Page', objectId: 'objects/leaked'),
          RetainingElement(kind: RetainingElementKind.closure, function: 'f', objectId: 'objects/closure', field: '_context'),
          RetainingElement(kind: RetainingElementKind.list, className: '_List', libraryUri: 'dart:core', objectId: 'objects/list', index: 0),
          RetainingElement(
            kind: RetainingElementKind.instance,
            className: '_Timer',
            libraryUri: 'dart:isolate',
            objectId: 'objects/timer',
            field: '_callback',
          ),
          RetainingElement(
            kind: RetainingElementKind.instance,
            className: 'Holder',
            libraryUri: 'package:app/holder.dart',
            objectId: 'objects/holder',
            field: 'x',
          ),
          RetainingElement(kind: RetainingElementKind.staticField, className: 'Registry', field: 'r'),
        ],
      );

      await traceOfOne();

      expect(vm.fieldReads, ['objects/holder']);
    });

    test('are asked about for no more than 40 steps of a long path, the ones nearest the leak', () async {
      vm.path = RetainingPathInfo(
        gcRootType: 'user global',
        hops: List.filled(62, 'hop'),
        elements: [
          const RetainingElement(kind: RetainingElementKind.instance, className: '_Page', objectId: 'objects/leaked'),
          for (var i = 0; i < 60; i++)
            RetainingElement(
              kind: RetainingElementKind.instance,
              className: 'Link',
              libraryUri: 'package:app/link.dart',
              objectId: 'objects/link$i',
              field: 'next',
            ),
          const RetainingElement(kind: RetainingElementKind.staticField, className: 'Registry', field: 'head'),
        ],
        totalLength: 62,
      );

      final trace = (await traceOfOne())!;

      expect(vm.fieldReads, [for (var i = 0; i < 40; i++) 'objects/link$i']);
      expect(trace.nodes, hasLength(62));
    });

    test('that the VM cannot say leave the step unclear, and the leak has its trace all the same', () async {
      // The fake has no facts for the id, as when it has expired.
      final trace = (await traceOfOne())!;

      expect(vm.fieldReads, ['objects/holder']);
      expect(_statuses(trace), 'EUS');
    });

    test('that fail to be read leave the step unclear, are logged, and the leak has its trace all the same', () async {
      final log = captureLog();
      vm.readFieldsError = StateError('the VM service went away');

      final trace = (await traceOfOne())!;

      expect(_statuses(trace), 'EUS');
      expect(log.lines.single, 'Could not read the fields of an object on a retaining path');
      expect(log.errors.single, isA<StateError>());
    });

    test('that something fails to make sense of cost the leak its trace, and not its report', () async {
      final log = captureLog();
      vm.fieldFacts['objects/holder'] = const _ExplodingFacts();

      final found = await leaks(_dump([_snapshot('a')]));

      expect(found, hasLength(1));
      expect(found.single.trace, isNull);
      expect(found.single.retainingPath, same(vm.path));
      expect(found.single.occurrenceCount, 1);
      expect(log.lines.single, 'Could not work out the trace of a retaining path');
    });
  });

  group('another object that is watched and retained', () {
    setUp(() {
      vm.path = _path(holderHash: 'holder'.hashCode);
      vm.pathsById['objects/holder'] = const RetainingPathInfo(
        gcRootType: 'user global',
        hops: ['Holder', 'Registry.holders'],
        elements: [
          RetainingElement(kind: RetainingElementKind.instance, className: 'Holder', libraryUri: 'package:app/holder.dart'),
          RetainingElement(
            kind: RetainingElementKind.staticField,
            className: 'Registry',
            libraryUri: 'package:app/registry.dart',
            field: 'holders',
          ),
        ],
      );
    });

    RetainedObjectSnapshot holder({bool collected = false}) => _snapshot(
      'holder',
      description: 'Holder received State#dispose() callback',
      vmObjectId: 'objects/holder',
      collected: collected,
    );

    test('is where the leak starts when the path goes through it: what it holds should be gone', () async {
      final found = await leaks(_dump([_snapshot('a'), holder()]));

      final trace = found.first.trace!;
      expect(_statuses(trace), 'ESS');
      expect(trace.nodes[1].note, 'Also expected to be gone: Holder received State#dispose() callback');
    });

    test('is nothing of the kind once it has been collected', () async {
      final found = await leaks(_dump([_snapshot('a'), holder(collected: true)]));

      expect(_statuses(found.single.trace!), 'EUS');
    });

    test('is nothing of the kind when it is not in the dump', () async {
      final found = await leaks(_dump([_snapshot('a')]));

      expect(_statuses(found.single.trace!), 'EUS');
    });
  });

  group('the ids the VM hands out', () {
    test('are in a zone of their own for each lookup, and for the reads of the fields of its path', () async {
      vm.fieldFacts['objects/holder'] = _stateOnScreen;

      await leaks(_dump([_snapshot('a')]));

      expect(vm.zonesOpened, ['zones/1']);
      expect(vm.pathZones, ['zones/1']);
      expect(vm.readZones, ['zones/1']);
    });

    test('are in the zone of their own leak, when there are several', () async {
      vm.pathsById['objects/other'] = _path();
      vm.fieldFacts['objects/holder'] = _stateOnScreen;

      await leaks(
        _dump([
          _snapshot('a'),
          _snapshot('b', description: 'another reason', vmObjectId: 'objects/other'),
        ]),
      );

      expect(vm.zonesOpened, ['zones/1', 'zones/2']);
      expect(vm.pathZones, ['zones/1', 'zones/2']);
      expect(vm.readZones, ['zones/1', 'zones/2'], reason: 'each leak reads in the zone of the lookup that gave it its ids');
    });

    test('are let go of when the leak has been worked out: no zone is left open', () async {
      vm.fieldFacts['objects/holder'] = _stateOnScreen;
      vm.pathsById['objects/other'] = _path();

      await leaks(
        _dump([
          _snapshot('a'),
          _snapshot('b', description: 'another reason', vmObjectId: 'objects/other'),
        ]),
      );

      expect(vm.zonesOpened, hasLength(2));
      expect(vm.zonesOpen, isEmpty);
    });

    test('are let go of at once when the lookup found no path: not held while the others are looked up', () async {
      vm.pathsById['objects/first'] = null;
      vm.pathsById['objects/second'] = _path();

      await leaks(
        _dump([
          _snapshot('a', vmObjectId: 'objects/first'),
          _snapshot('b', description: 'another reason', vmObjectId: 'objects/second'),
        ]),
      );

      expect(vm.zoneEvents.take(4), ['open zones/1', 'path zones/1', 'close zones/1', 'open zones/2']);
      expect(vm.zonesOpen, isEmpty);
    });

    test('are let go of at once when the lookup found nothing holding the object', () async {
      vm.pathsById['objects/first'] = const RetainingPathInfo(gcRootType: 'class table', hops: []);
      vm.pathsById['objects/second'] = _path();

      await leaks(
        _dump([
          _snapshot('a', vmObjectId: 'objects/first'),
          _snapshot('b', description: 'another reason', vmObjectId: 'objects/second'),
        ]),
      );

      expect(vm.zoneEvents.take(4), ['open zones/1', 'path zones/1', 'close zones/1', 'open zones/2']);
    });

    test('are let go of as soon as the leak has been worked out, before the next one is read', () async {
      vm.pathsById['objects/other'] = _path();
      vm.fieldFacts['objects/holder'] = _stateOnScreen;

      await leaks(
        _dump([
          _snapshot('a'),
          _snapshot('b', description: 'another reason', vmObjectId: 'objects/other'),
        ]),
      );

      expect(vm.zoneEvents, [
        'open zones/1',
        'path zones/1',
        'open zones/2',
        'path zones/2',
        'read zones/1',
        'close zones/1',
        'read zones/2',
        'close zones/2',
      ]);
    });

    test('are let go of when the analysis fails half way', () async {
      vm.onRetainingPath = () => throw StateError('the VM went away');

      final analysis = await analyzer.analyze(_dump([_snapshot('a')]));

      expect(analysis, isA<HeapAnalysisFailure>());
      expect(vm.zonesOpened, ['zones/1']);
      expect(vm.zonesOpen, isEmpty, reason: 'a zone that is left open holds what it named for good');
    });

    test('are not given a zone when no path is looked up', () async {
      config = const LeakSentryConfig(enableRetainingPathAnalysis: false);
      await leaks(_dump([_snapshot('a')]));
      await leaks(_dump([_snapshot('b')], isolateId: null));

      expect(vm.zonesOpened, isEmpty);
    });

    test('are in the VM\'s shared ring when the VM has no zones to give: the lookup is made all the same', () async {
      vm.idZonesSupported = false;
      vm.fieldFacts['objects/holder'] = _stateOnScreen;

      final trace = (await traceOfOne())!;

      expect(vm.pathZones, [null]);
      expect(vm.readZones, [null]);
      expect(_statuses(trace), 'EES');
    });

    test('are in the shared ring, and it is logged, when opening a zone fails', () async {
      final log = captureLog();
      vm.openIdZoneError = StateError('the VM service went away');

      final trace = (await traceOfOne())!;

      expect(vm.pathZones, [null]);
      expect(trace, isNotNull);
      expect(log.lines.single, 'Could not open a zone for the ids of a lookup');
    });

    test('are let go of in a zone that fails to be emptied: it is logged and costs the leak nothing', () async {
      final log = captureLog();
      vm.closeIdZoneError = StateError('the VM service went away');

      final found = await leaks(_dump([_snapshot('a')]));

      expect(found, hasLength(1));
      expect(found.single.trace, isNotNull);
      expect(log.lines.single, 'Could not empty the zone of the ids of a lookup');
    });
  });

  group('progress', () {
    test('says the traces are being built before it starts to read fields', () async {
      vm.fieldFacts['objects/holder'] = _stateDisposed;
      final readsAtStep = <AnalysisStep, int>{};

      await leaks(_dump([_snapshot('a')]), onProgress: (step, _) => readsAtStep[step] = vm.fieldReads.length);

      expect(readsAtStep[AnalysisStep.findingPathsToRetainedObjects], 0);
      expect(readsAtStep[AnalysisStep.buildingLeakTraces], 0);
      expect(vm.fieldReads, ['objects/holder']);
    });
  });
}
