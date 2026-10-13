import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/analysis/node_status.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/retaining_element.dart';

class _Page {}

const _created = CreationSite(uri: 'package:app/page.dart', member: '_PageState.initState', line: 42, column: 11);
const _watched = CreationSite(uri: 'package:app/page.dart', member: '_PageState.build', line: 77, column: 5);
const _declared = CreationSite(uri: 'package:app/page.dart', member: '_PageState', line: 12, column: 1);

LeakReport _report({
  CreationSite? creationSite,
  CreationSite? watchSite,
  CreationSite? classSite,
  CreationSiteGap? gap,
  RetainingPathInfo? path,
  LeakTrace? trace,
}) => LeakReport(
  type: _Page,
  reason: 'a reason',
  firstObservedAt: DateTime(2026),
  detectedAt: DateTime(2026),
  confidence: LeakConfidence.retainedAfterGc,
  signature: 'signature',
  creationSite: creationSite,
  watchSite: watchSite,
  classSite: classSite,
  creationSiteGap: gap,
  retainingPath: path,
  trace: trace,
);

void main() {
  group('a report says where to start looking, or why that is not known', () {
    test('where the object was created', () {
      expect(_report(creationSite: _created).toString(), contains('createdAt: _PageState.initState (package:app/page.dart:42:11)'));
    });

    test('where it was handed to the watcher, when its creation is not known', () {
      final text = _report(watchSite: _watched).toString();

      expect(text, contains('watchedAt: _PageState.build (package:app/page.dart:77:5)'));
      expect(text, isNot(contains('createdAt')));
      expect(text, isNot(contains('unavailable')));
    });

    test('why neither is known', () {
      final text = _report(gap: CreationSiteGap.onlyFrameworkFrames).toString();

      expect(text, contains('creation site unavailable (onlyFrameworkFrames)'));
      expect(text, isNot(contains('createdAt')));
    });

    test('where the class is declared, next to why the creation is not known', () {
      final text = _report(gap: CreationSiteGap.onlyFrameworkFrames, classSite: _declared).toString();

      expect(text, contains('creation site unavailable (onlyFrameworkFrames)'));
      expect(text, contains('classDeclaredAt: _PageState (package:app/page.dart:12:1)'));
    });

    test('the class is left out when the creation site is known', () {
      expect(_report(creationSite: _created, classSite: _declared).toString(), isNot(contains('classDeclaredAt')));
    });

    test('a report that knows nothing says so only when it has a reason', () {
      expect(_report().toString(), isNot(contains('unavailable')));
    });

    test('the likely cause, when the path was worked out, comes before the path', () {
      const trace = LeakTrace(
        gcRootType: 'user global',
        nodes: [
          TraceNode(
            kind: TraceNodeKind.staticHolder,
            name: 'Registry',
            status: NodeStatus.inUse,
            reference: TraceReference(kind: TraceReferenceKind.staticVariable, name: '.pages', genericName: 'pages', isSuspect: true),
          ),
          TraceNode(kind: TraceNodeKind.instance, name: '_Page', status: NodeStatus.shouldBeGone),
        ],
      );

      final text = _report(
        creationSite: _created,
        path: const RetainingPathInfo(gcRootType: 'user global', hops: ['_Page', 'Registry.pages']),
        trace: trace,
      ).toString();

      expect(text, contains('likelyCause: Registry.pages'));
      expect(text.indexOf('createdAt'), lessThan(text.indexOf('likelyCause')));
      expect(text.indexOf('likelyCause'), lessThan(text.indexOf('retainingPath')));
    });

    test('says no cause when the trace names none', () {
      const trace = LeakTrace(gcRootType: 'user global', nodes: [TraceNode(kind: TraceNodeKind.instance, name: '_Page')]);

      expect(_report(creationSite: _created, trace: trace).toString(), isNot(contains('likelyCause')));
      expect(_report(creationSite: _created).toString(), isNot(contains('likelyCause')));
    });

    test('the retaining path still comes last', () {
      final text = _report(
        creationSite: _created,
        path: const RetainingPathInfo(gcRootType: 'user global', hops: ['_Page', 'Holder.field']),
      ).toString();

      expect(text.indexOf('createdAt'), lessThan(text.indexOf('retainingPath')));
    });
  });

  group('a retaining path cut short', () {
    RetainingPathInfo path({int? totalLength, int elements = 3}) => RetainingPathInfo(
      gcRootType: 'user global',
      hops: List.filled(elements, 'hop'),
      elements: List.filled(elements, const RetainingElement(kind: RetainingElementKind.instance)),
      totalLength: totalLength,
    );

    test('counts the steps left out', () {
      expect(path(totalLength: 10).hiddenSteps, 7);
    });

    test('a path that is whole leaves none out', () {
      expect(path().hiddenSteps, 0);
      expect(path(totalLength: 3).hiddenSteps, 0);
    });

    test('a total shorter than what was kept is not a negative count', () {
      expect(path(totalLength: 1).hiddenSteps, 0);
    });
  });
}
