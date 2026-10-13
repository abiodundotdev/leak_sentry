import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/heap_analysis.dart';
import 'package:leak_sentry/analysis/heap_analyzer.dart';
import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/leak_sentry_stats.dart';
import 'package:leak_sentry/object_watcher/keyed_weak_reference.dart';

import 'fakes/fake_vm_bridge.dart';

class _Page {}

class _Controller {}

StackTrace _stackFrom(String member, int line) => StackTrace.fromString(
  '#0      $member (package:my_app/screens/page.dart:$line:7)\n'
  '#1      main (package:my_app/main.dart:3:1)\n',
);

RetainedObjectSnapshot _snapshot(
  String key, {
  Type type = _Page,
  String description = '_Page received State#dispose() callback',
  StackTrace? creationStack,
  String? vmObjectId = 'objects/1',
  DateTime? watchedAt,
  bool collected = false,
  void Function()? onResolve,
}) => RetainedObjectSnapshot(
  key: key,
  description: description,
  type: type,
  identityHash: key.hashCode,
  watchUptime: Duration.zero,
  retainedUptime: const Duration(seconds: 5),
  watchedAt: watchedAt ?? DateTime(2026, 1, 1),
  creationStack: creationStack,
  vmObjectIdResolver: vmObjectId == null
      ? null
      : () {
          onResolve?.call();
          return collected ? null : vmObjectId;
        },
  collectedProbe: () => collected,
);

RetainedObjectsDump _dump(List<RetainedObjectSnapshot> objects, {String? isolateId = 'isolates/1'}) =>
    RetainedObjectsDump(objects: objects, dumpUptime: const Duration(seconds: 6), isolateId: isolateId);

void main() {
  late FakeVmBridge vm;
  late LeakSentryStats stats;
  late LeakSentryConfig config;
  late RetainedSetHeapAnalyzer analyzer;

  setUp(() {
    vm = FakeVmBridge();
    stats = LeakSentryStats();
    config = const LeakSentryConfig();
    analyzer = RetainedSetHeapAnalyzer(vm: vm, config: () => config, stats: stats);
  });

  Future<HeapAnalysisSuccess> analyze(RetainedObjectsDump dump, {AnalysisProgressListener? onProgress}) async {
    final analysis = await analyzer.analyze(dump, onProgress: onProgress);
    expect(analysis, isA<HeapAnalysisSuccess>());
    return analysis as HeapAnalysisSuccess;
  }

  test('an empty dump has no leaks', () async {
    final analysis = await analyze(_dump([]));

    expect(analysis.leaks, isEmpty);
    expect(vm.retainingPathCalls, 0);
  });

  test('a retained object becomes a leak with what is known about it', () async {
    final watchedAt = DateTime(2026, 3, 4, 5, 6, 7);
    final analysis = await analyze(
      _dump([_snapshot('a', creationStack: _stackFrom('_PageState.initState', 42), watchedAt: watchedAt)]),
    );

    final leak = analysis.leaks.single;
    expect(leak.type, _Page);
    expect(leak.reason, '_Page received State#dispose() callback');
    expect(leak.confidence, LeakConfidence.retainedAfterGc);
    expect(leak.firstObservedAt, watchedAt);
    expect(leak.objectId, 'objects/1');
    expect(leak.retainingPath, same(vm.path));
    expect(leak.creationSite?.member, '_PageState.initState');
    expect(leak.creationSite?.line, 42);
    expect(leak.creationSite?.uri, 'package:my_app/screens/page.dart');
    expect(leak.occurrenceCount, 1);
  });

  group('grouping', () {
    test('objects that leak the same way are one leak, and cost one lookup', () async {
      final stack = _stackFrom('_PageState.initState', 42);
      final analysis = await analyze(
        _dump([
          _snapshot('a', creationStack: stack),
          _snapshot('b', creationStack: stack),
          _snapshot('c', creationStack: stack),
        ]),
      );

      expect(analysis.leaks, hasLength(1));
      expect(analysis.leaks.single.occurrenceCount, 3);
      expect(vm.retainingPathCalls, 1);
      expect(stats.retainingPathLookups, 1);
      expect(stats.duplicatesSkipped, 2);
    });

    test('objects created at different places are different leaks', () async {
      final analysis = await analyze(
        _dump([
          _snapshot('a', creationStack: _stackFrom('_createHere', 10)),
          _snapshot('b', creationStack: _stackFrom('_createThere', 20)),
        ]),
      );

      expect(analysis.leaks.map((leak) => leak.creationSite?.member), ['_createHere', '_createThere']);
      expect(vm.retainingPathCalls, 2);
    });

    test('objects of different types or reasons are different leaks', () async {
      final analysis = await analyze(
        _dump([
          _snapshot('a'),
          _snapshot('b', type: _Controller),
          _snapshot('c', description: 'something else'),
        ]),
      );

      expect(analysis.leaks, hasLength(3));
    });

    test('objects with no known creation site group together', () async {
      final analysis = await analyze(_dump([_snapshot('a'), _snapshot('b')]));

      expect(analysis.leaks.single.occurrenceCount, 2);
      expect(analysis.leaks.single.creationSite, isNull);
    });

    test('keeps the order in which leaks were first seen', () async {
      final analysis = await analyze(
        _dump([
          _snapshot('a', type: _Controller),
          _snapshot('b'),
          _snapshot('c', type: _Controller),
        ]),
      );

      expect(analysis.leaks.map((leak) => leak.type), [_Controller, _Page]);
      expect(analysis.leaks.first.occurrenceCount, 2);
    });
  });

  group('retaining paths', () {
    test('are looked up with the isolate and object ids of the dump', () async {
      String? seenIsolate;
      String? seenObject;
      final recording = _RecordingVm(vm, (isolate, object) {
        seenIsolate = isolate;
        seenObject = object;
      });
      analyzer = RetainedSetHeapAnalyzer(vm: recording, config: () => config, stats: stats);

      await analyze(_dump([_snapshot('a', vmObjectId: 'objects/77')], isolateId: 'isolates/9'));

      expect(seenIsolate, 'isolates/9');
      expect(seenObject, 'objects/77');
    });

    test('are not looked up when the config turns them off', () async {
      config = const LeakSentryConfig(enableRetainingPathAnalysis: false);

      final analysis = await analyze(_dump([_snapshot('a')]));

      expect(vm.retainingPathCalls, 0);
      expect(analysis.leaks.single.retainingPath, isNull);
      expect(analysis.leaks, hasLength(1), reason: 'the leak is still reported, only without its path');
    });

    test('are not looked up when the dump has no isolate or the object has no id', () async {
      await analyze(_dump([_snapshot('a')], isolateId: null));
      await analyze(_dump([_snapshot('b', vmObjectId: null)]));

      expect(vm.retainingPathCalls, 0);
    });

    test('are looked up for the first leaks only, up to the configured limit', () async {
      config = const LeakSentryConfig(maxRetainingPathLookups: 2);
      final analysis = await analyze(
        _dump([
          for (var i = 0; i < 4; i++) _snapshot('k$i', creationStack: _stackFrom('_create$i', i + 1)),
        ]),
      );

      expect(vm.retainingPathCalls, 2);
      expect(analysis.leaks.map((leak) => leak.retainingPath != null), [true, true, false, false]);
      expect(analysis.leaks, hasLength(4));
    });

    test('a lookup the VM could not answer leaves the leak without a path', () async {
      vm.path = null;

      final analysis = await analyze(_dump([_snapshot('a')]));

      expect(analysis.leaks.single.retainingPath, isNull);
      expect(analysis.unreachableObjectCount, 0, reason: 'no answer is not the same as no path');
      expect(stats.retainingPathLookups, 1);
    });

    test('an id is asked for only for the representative of each leak, because an id pins the object', () async {
      var resolved = 0;
      await analyze(
        _dump([for (var i = 0; i < 5; i++) _snapshot('k$i', onResolve: () => resolved++)]),
      );

      expect(resolved, 1, reason: 'five objects of one leak are one lookup');
    });

    test('an id is not asked for at all for a leak beyond the lookup limit', () async {
      config = const LeakSentryConfig(maxRetainingPathLookups: 1);
      final resolvedFor = <String>[];
      await analyze(
        _dump([
          for (var i = 0; i < 3; i++)
            _snapshot('k$i', creationStack: _stackFrom('_create$i', i + 1), onResolve: () => resolvedFor.add('k$i')),
        ]),
      );

      expect(resolvedFor, ['k0']);
    });

    test('no id is asked for when paths are turned off', () async {
      config = const LeakSentryConfig(enableRetainingPathAnalysis: false);
      var resolved = 0;

      await analyze(_dump([_snapshot('a', onResolve: () => resolved++)]));

      expect(resolved, 0);
    });
  });

  group('objects nothing retains anymore', () {
    test('a path of no elements means unreachable: not a leak, but counted', () async {
      vm.path = const RetainingPathInfo(gcRootType: 'class table', hops: []);

      final analysis = await analyze(_dump([_snapshot('a'), _snapshot('b')]));

      expect(analysis.leaks, isEmpty);
      expect(analysis.unreachableObjectCount, 2, reason: 'both objects of the one leak');
    });

    test('is decided per leak: the others are still reported', () async {
      final paths = <String, RetainingPathInfo>{
        'objects/1': const RetainingPathInfo(gcRootType: 'class table', hops: []),
        'objects/2': const RetainingPathInfo(gcRootType: 'user global', hops: ['Leaked', 'Holder.field']),
      };
      analyzer = RetainedSetHeapAnalyzer(vm: _PathsVm(paths), config: () => config, stats: stats);

      final analysis = await analyze(
        _dump([
          _snapshot('a', vmObjectId: 'objects/1', creationStack: _stackFrom('_createHere', 10)),
          _snapshot('b', vmObjectId: 'objects/2', creationStack: _stackFrom('_createThere', 20)),
        ]),
      );

      expect(analysis.leaks.map((leak) => leak.creationSite?.member), ['_createThere']);
      expect(analysis.unreachableObjectCount, 1);
    });

    test('an object collected since the dump is unreachable, and not counted in its leak', () async {
      final resolvedFor = <String>[];
      final analysis = await analyze(
        _dump([
          _snapshot('gone', collected: true, onResolve: () => resolvedFor.add('gone')),
          _snapshot('b', onResolve: () => resolvedFor.add('b')),
          _snapshot('c', onResolve: () => resolvedFor.add('c')),
        ]),
      );

      expect(analysis.leaks.single.occurrenceCount, 2);
      expect(analysis.unreachableObjectCount, 1);
      expect(resolvedFor, ['b'], reason: 'the representative is the first object still alive');
    });

    test('a leak whose objects were all collected is unreachable and costs no lookup', () async {
      final analysis = await analyze(
        _dump([_snapshot('a', collected: true), _snapshot('b', collected: true)]),
      );

      expect(analysis.leaks, isEmpty);
      expect(analysis.unreachableObjectCount, 2);
      expect(vm.retainingPathCalls, 0);
    });

    test('with no way to tell whether an object was collected, it is assumed alive', () async {
      final analysis = await analyze(_dump([_snapshot('a', vmObjectId: null)]));

      expect(analysis.leaks, hasLength(1));
      expect(analysis.unreachableObjectCount, 0);
    });

    test('no path is looked up, so none can say unreachable, when paths are turned off', () async {
      config = const LeakSentryConfig(enableRetainingPathAnalysis: false);
      vm.path = const RetainingPathInfo(gcRootType: 'class table', hops: []);

      final analysis = await analyze(_dump([_snapshot('a')]));

      expect(analysis.leaks, hasLength(1));
      expect(analysis.unreachableObjectCount, 0);
    });
  });

  group('progress', () {
    test('reports the steps in order, with how far along each is', () async {
      final steps = <(AnalysisStep, double)>[];

      await analyze(_dump([_snapshot('a')]), onProgress: (step, percent) => steps.add((step, percent)));

      expect(steps.map((entry) => entry.$1), [
        AnalysisStep.findingRetainedObjects,
        AnalysisStep.findingPathsToRetainedObjects,
        AnalysisStep.buildingLeakTraces,
      ]);
      for (final (step, percent) in steps) {
        expect(percent, step.index / AnalysisStep.values.length);
      }
    });

    test('waits for the progress listener, so it can hold the analysis up', () async {
      final order = <String>[];
      vm.onRetainingPath = () => order.add('lookup');

      await analyze(
        _dump([_snapshot('a')]),
        onProgress: (step, _) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          order.add(step.name);
        },
      );

      expect(order, ['findingRetainedObjects', 'findingPathsToRetainedObjects', 'lookup', 'buildingLeakTraces']);
    });

    test('a step has a readable name, and the steps are ordered from parsing the heap dump to reporting the analysis', () {
      expect(AnalysisStep.findingPathsToRetainedObjects.humanReadableName, 'Finding paths to retained objects');
      expect(AnalysisStep.parsingHeapDump.index, 0);
      expect(AnalysisStep.reportingHeapAnalysis.index, AnalysisStep.values.length - 1);
    });
  });

  group('result', () {
    test('records how long the analysis took and which dump it was of', () async {
      final dump = _dump([_snapshot('a')]);

      final analysis = await analyze(dump);

      expect(analysis.dump, same(dump));
      expect(analysis.analysisDuration, greaterThanOrEqualTo(Duration.zero));
      expect(stats.analyses, 1);
      expect(stats.analysisMicros, greaterThanOrEqualTo(0));
    });

    test('prints a framed report of the leak counts, the unreachable objects and the duration', () async {
      final analysis = await analyze(_dump([_snapshot('a'), _snapshot('b', type: _Controller)]));

      final text = analysis.toString();
      expect(text, contains('HEAP ANALYSIS RESULT'));
      expect(text, contains('2 APPLICATION LEAKS'));
      expect(text, contains('0 UNREACHABLE OBJECTS'));
      expect(text, contains('An unreachable object is still in memory but LeakSentry could not find a strong reference path'));
      expect(text, contains('Analysis duration:'));
      expect(text, startsWith('====================================\nHEAP ANALYSIS RESULT\n'));
      expect(text, endsWith('===================================='));
    });

    test('says LEAK and OBJECT, not LEAKS and OBJECTS, for a single one', () async {
      vm.path = const RetainingPathInfo(gcRootType: 'user global', hops: ['Leaked']);
      final analysis = await analyze(_dump([_snapshot('a')]));

      expect(analysis.toString(), contains('1 APPLICATION LEAK\n'));
      expect(analysis.toString(), contains('0 UNREACHABLE OBJECTS\n'));

      vm.path = const RetainingPathInfo(gcRootType: 'class table', hops: []);
      final unreachable = await analyze(_dump([_snapshot('a')]));
      expect(unreachable.toString(), contains('1 UNREACHABLE OBJECT\n'));
    });

    test('prints the metadata when there is some', () {
      final analysis = HeapAnalysisSuccess(
        dump: _dump([]),
        analysisDuration: const Duration(milliseconds: 12),
        leaks: const [],
        metadata: const {'Flutter version': '3.44.2'},
      );

      final text = analysis.toString();
      expect(text, contains('METADATA'));
      expect(text, contains('Please include this in bug reports and Stack Overflow questions.'));
      expect(text, contains('Flutter version: 3.44.2'));
      expect(text, contains('Analysis duration: 12 ms'));
    });

    test('a failure is returned, not thrown, and still counts as an analysis', () async {
      final failing = _ThrowingVm();
      analyzer = RetainedSetHeapAnalyzer(vm: failing, config: () => config, stats: stats);
      final dump = _dump([_snapshot('a')]);

      final analysis = await analyzer.analyze(dump);

      expect(analysis, isA<HeapAnalysisFailure>());
      final failure = analysis as HeapAnalysisFailure;
      expect(failure.exception, isA<StateError>());
      expect(failure.stackTrace, isNotNull);
      expect(failure.dump, same(dump));
      expect(failure.toString(), contains('HEAP ANALYSIS FAILED'));
      expect(stats.analyses, 1);
    });
  });
}

class _RecordingVm extends FakeVmBridge {
  _RecordingVm(this._inner, this._onLookup);

  final FakeVmBridge _inner;
  final void Function(String isolateId, String objectId) _onLookup;

  @override
  Future<RetainingPathInfo?> retainingPath(String isolateId, String objectId, {String? idZoneId}) {
    _onLookup(isolateId, objectId);
    return _inner.retainingPath(isolateId, objectId, idZoneId: idZoneId);
  }
}

class _ThrowingVm extends FakeVmBridge {
  @override
  Future<RetainingPathInfo?> retainingPath(String isolateId, String objectId, {String? idZoneId}) => throw StateError('vm gone');
}

class _PathsVm extends FakeVmBridge {
  _PathsVm(this._paths);

  final Map<String, RetainingPathInfo> _paths;

  @override
  Future<RetainingPathInfo?> retainingPath(String isolateId, String objectId, {String? idZoneId}) async => _paths[objectId];
}
