import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/heap_analysis.dart';
import 'package:leak_sentry/analysis/heap_analyzer.dart';
import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/leak_sentry_stats.dart';
import 'package:leak_sentry/models/retaining_element.dart';
import 'package:leak_sentry/object_watcher/keyed_weak_reference.dart';

import 'fakes/fake_vm_bridge.dart';

class _Page {}

class _Other {}

StackTrace _stackAt(String member, int line, {String file = 'page'}) =>
    StackTrace.fromString('#0      $member (package:my_app/$file.dart:$line:7)\n#1      main (package:my_app/main.dart:3:1)\n');

/// What Flutter reports for a State with no initState of its own: only framework frames.
final StackTrace _frameworkOnly = StackTrace.fromString(
  '#0      State.initState (package:flutter/src/widgets/framework.dart:1010:12)\n'
  '#1      StatefulElement._firstBuild (package:flutter/src/widgets/framework.dart:5950:55)\n',
);

final StackTrace _unreadable = StackTrace.fromString('this is not a stack trace');

RetainedObjectSnapshot _snapshot(
  String key, {
  Type type = _Page,
  String description = '_Page received State#dispose() callback',
  StackTrace? creationStack,
  StackTrace? watchStack,
  String? vmObjectId = 'objects/1',
}) => RetainedObjectSnapshot(
  key: key,
  description: description,
  type: type,
  identityHash: key.hashCode,
  watchUptime: Duration.zero,
  retainedUptime: const Duration(seconds: 5),
  watchedAt: DateTime(2026, 1, 1),
  creationStack: creationStack,
  watchStack: watchStack,
  vmObjectIdResolver: vmObjectId == null ? null : () => vmObjectId,
  collectedProbe: () => false,
);

RetainedObjectsDump _dump(List<RetainedObjectSnapshot> objects, {String? isolateId = 'isolates/1'}) =>
    RetainedObjectsDump(objects: objects, dumpUptime: const Duration(seconds: 6), isolateId: isolateId);

void main() {
  late FakeVmBridge vm;
  late LeakSentryConfig config;
  late RetainedSetHeapAnalyzer analyzer;

  setUp(() {
    vm = FakeVmBridge();
    config = const LeakSentryConfig();
    analyzer = RetainedSetHeapAnalyzer(vm: vm, config: () => config, stats: LeakSentryStats());
  });

  Future<List<LeakReport>> analyze(List<RetainedObjectSnapshot> objects, {String? isolateId = 'isolates/1'}) async {
    final analysis = await analyzer.analyze(_dump(objects, isolateId: isolateId));
    expect(analysis, isA<HeapAnalysisSuccess>());
    return (analysis as HeapAnalysisSuccess).leaks;
  }

  group('where a leaked object came from', () {
    test('the line that created it, when Flutter saw it created', () async {
      final report = (await analyze([_snapshot('a', creationStack: _stackAt('_PageState.initState', 42))])).single;

      expect(report.creationSite?.member, '_PageState.initState');
      expect(report.creationSite?.line, 42);
      expect(report.watchSite, isNull);
      expect(report.creationSiteGap, isNull);
    });

    test('else the line that handed it to the watcher', () async {
      final report = (await analyze([_snapshot('a', watchStack: _stackAt('_PageState.build', 77))])).single;

      expect(report.creationSite, isNull);
      expect(report.watchSite?.member, '_PageState.build');
      expect(report.watchSite?.line, 77);
      expect(report.creationSiteGap, isNull);
    });

    test('the creation site wins over the watch site', () async {
      final report = (await analyze([
        _snapshot('a', creationStack: _stackAt('_PageState.initState', 42), watchStack: _stackAt('_PageState.build', 77)),
      ])).single;

      expect(report.creationSite?.line, 42);
      expect(report.watchSite, isNull);
    });

    test('a creation stack with nothing to show falls back to the watch site', () async {
      final report = (await analyze([_snapshot('a', creationStack: _frameworkOnly, watchStack: _stackAt('_PageState.build', 77))])).single;

      expect(report.creationSite, isNull);
      expect(report.watchSite?.line, 77);
      expect(report.creationSiteGap, isNull);
    });

    test('else why it is not known: a State that has no initState of its own', () async {
      final report = (await analyze([_snapshot('a', creationStack: _frameworkOnly)])).single;

      expect(report.creationSite, isNull);
      expect(report.watchSite, isNull);
      expect(report.creationSiteGap, CreationSiteGap.onlyFrameworkFrames);
      expect(report.toString(), contains('creation site unavailable (onlyFrameworkFrames)'));
    });

    test('else why: Flutter never reported the object being created', () async {
      final report = (await analyze([_snapshot('a')])).single;

      expect(report.creationSiteGap, CreationSiteGap.notAnnounced);
    });

    test('when neither stack can be used, the creation stack that was read explains it', () async {
      final report = (await analyze([_snapshot('a', creationStack: _frameworkOnly, watchStack: _unreadable)])).single;

      expect(report.creationSiteGap, CreationSiteGap.onlyFrameworkFrames);
    });

    test('when only the watch stack exists, and it cannot be used, that explains it', () async {
      final report = (await analyze([_snapshot('a', watchStack: _unreadable)])).single;

      expect(report.creationSiteGap, CreationSiteGap.unparseable);
    });
  });

  group('leaks that are told apart by where they came from', () {
    test('objects handed over at different lines are different leaks', () async {
      final reports = await analyze([
        _snapshot('a', watchStack: _stackAt('first', 10)),
        _snapshot('b', watchStack: _stackAt('second', 20)),
      ]);

      expect(reports, hasLength(2));
      expect(reports.map((report) => report.watchSite?.line), unorderedEquals([10, 20]));
      expect(reports.map((report) => report.signature).toSet(), hasLength(2));
    });

    test('objects handed over at the same line are one leak', () async {
      final reports = await analyze([
        _snapshot('a', watchStack: _stackAt('first', 10)),
        _snapshot('b', watchStack: _stackAt('first', 10)),
      ]);

      expect(reports.single.occurrenceCount, 2);
    });

    test('a creation site and a watch site at the same line are not mixed up', () async {
      final reports = await analyze([
        _snapshot('a', creationStack: _stackAt('make', 10)),
        _snapshot('b', watchStack: _stackAt('make', 10)),
      ]);

      expect(reports, hasLength(2));
    });

    test('objects with no site at all are still one leak, as they always were', () async {
      final reports = await analyze([_snapshot('a'), _snapshot('b')]);

      expect(reports.single.occurrenceCount, 2);
      expect(reports.single.signature, '$_Page|${LeakConfidence.retainedAfterGc}|_Page received State#dispose() callback');
    });

    test('a signature that has a creation site is what it was before sites had reasons', () async {
      final report = (await analyze([_snapshot('a', creationStack: _stackAt('_PageState.initState', 42))])).single;

      expect(report.signature, '$_Page|${LeakConfidence.retainedAfterGc}|_Page received State#dispose() callback|package:my_app/page.dart:42');
    });
  });

  group('the class of a leaked object', () {
    RetainingPathInfo pathWith(RetainingElementKind kind, {CreationSite? declaredAt}) => RetainingPathInfo(
      gcRootType: 'user global',
      hops: const ['_Page', 'Holder.field'],
      elements: [
        RetainingElement(kind: kind, className: '_Page', declaredAt: declaredAt),
        const RetainingElement(kind: RetainingElementKind.staticField, className: 'Holder', field: 'field'),
      ],
    );

    test('says where it is declared, when the VM answered with the path', () async {
      vm.path = pathWith(
        RetainingElementKind.instance,
        declaredAt: const CreationSite(uri: 'package:my_app/page.dart', member: '_Page', line: 12, column: 1),
      );

      final report = (await analyze([_snapshot('a', creationStack: _frameworkOnly)])).single;

      expect(report.classSite?.member, '_Page');
      expect(report.classSite?.line, 12);
      expect(report.toString(), contains('classDeclaredAt: _Page (package:my_app/page.dart:12:1)'));
    });

    test('is not known without a path', () async {
      vm.path = null;

      expect((await analyze([_snapshot('a', creationStack: _frameworkOnly)])).single.classSite, isNull);
    });

    test('is not taken from something that is not an object', () async {
      vm.path = pathWith(
        RetainingElementKind.closure,
        declaredAt: const CreationSite(uri: 'package:my_app/page.dart', line: 12),
      );

      expect((await analyze([_snapshot('a')])).single.classSite, isNull);
    });
  });

  group('why a leak has no retaining path', () {
    test('there is none to explain when the VM answered', () async {
      expect((await analyze([_snapshot('a')])).single.pathGap, isNull);
    });

    test('the lookup is turned off', () async {
      config = const LeakSentryConfig(enableRetainingPathAnalysis: false);

      final report = (await analyze([_snapshot('a')])).single;

      expect(report.retainingPath, isNull);
      expect(report.pathGap, RetainingPathGap.disabled);
      expect(vm.retainingPathCalls, 0);
    });

    test('the app has no VM service', () async {
      final report = (await analyze([_snapshot('a')], isolateId: null)).single;

      expect(report.pathGap, RetainingPathGap.noVmService);
    });

    test('the analysis has looked up as many paths as it may', () async {
      config = const LeakSentryConfig(maxRetainingPathLookups: 1);

      final reports = await analyze([_snapshot('a'), _snapshot('b', type: _Other)]);

      expect(reports.map((report) => report.pathGap), [null, RetainingPathGap.lookupLimitReached]);
    });

    test('the VM has no id for the object', () async {
      final report = (await analyze([_snapshot('a', vmObjectId: null)])).single;

      expect(report.pathGap, RetainingPathGap.objectUnavailable);
      expect(report.objectId, isNull);
    });

    test('the lookup failed', () async {
      vm.path = null;

      final report = (await analyze([_snapshot('a')])).single;

      expect(report.retainingPath, isNull);
      expect(report.pathGap, RetainingPathGap.lookupFailed);
    });
  });

  group('every leak report has a place to start looking, or says why not', () {
    final stacks = <String, StackTrace?>{
      'none': null,
      'application code': _stackAt('_PageState.initState', 42),
      'framework code only': _frameworkOnly,
      'unreadable': _unreadable,
    };

    for (final creation in stacks.entries) {
      for (final watch in stacks.entries) {
        test('creation stack: ${creation.key}, watch stack: ${watch.key}', () async {
          final report = (await analyze([_snapshot('a', creationStack: creation.value, watchStack: watch.value)])).single;

          expect(
            report.creationSite != null || report.watchSite != null || report.creationSiteGap != null,
            isTrue,
            reason: '$report has neither a site nor a reason',
          );
          expect(
            report.creationSiteGap == null || (report.creationSite == null && report.watchSite == null),
            isTrue,
            reason: 'a reason is only given when there is no site: $report',
          );
          expect(report.creationSite == null || report.watchSite == null, isTrue, reason: 'one site only: $report');
        });
      }
    }
  });
}
