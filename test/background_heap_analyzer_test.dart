import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/background_heap_analyzer.dart';
import 'package:leak_sentry/analysis/heap_analysis.dart';
import 'package:leak_sentry/analysis/heap_analyzer.dart';
import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/core/leak_report_hub.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';
import 'package:leak_sentry/models/leak_report.dart';

const _dump = RetainedObjectsDump(objects: [], dumpUptime: Duration(seconds: 3));

LeakReport _leak(String signature) => LeakReport(
  type: String,
  reason: signature,
  firstObservedAt: DateTime(2026),
  detectedAt: DateTime(2026),
  confidence: LeakConfidence.retainedAfterGc,
  signature: signature,
);

class _FakeAnalyzer implements HeapAnalyzer {
  _FakeAnalyzer(this._result, {this.steps = const []});

  final HeapAnalysis Function(RetainedObjectsDump dump) _result;
  final List<AnalysisStep> steps;
  int calls = 0;

  @override
  Future<HeapAnalysis> analyze(RetainedObjectsDump dump, {AnalysisProgressListener? onProgress}) async {
    calls++;
    for (final step in steps) {
      await onProgress?.call(step, step.progressPercent);
    }
    return _result(dump);
  }
}

void main() {
  late LeakReportHub hub;
  late List<LeakSentryEvent> sent;

  setUp(() {
    hub = LeakReportHub();
    sent = [];
  });

  BackgroundHeapAnalyzer listener(HeapAnalyzer analyzer, {Future<void> Function(LeakSentryEvent)? sendEvent}) =>
      BackgroundHeapAnalyzer(
        analyzer: analyzer,
        hub: hub,
        sendEvent: sendEvent ?? (event) async => sent.add(event),
      );

  HeapDumpEvent heapDump([String id = 'dump-1']) =>
      HeapDumpEvent(id, dump: _dump, duration: const Duration(milliseconds: 5), reason: 'test');

  test('analyzes a heap dump: progress first, then the result, all under the dump\'s event id', () async {
    final analyzer = _FakeAnalyzer(
      (dump) => HeapAnalysisSuccess(dump: dump, analysisDuration: Duration.zero, leaks: [_leak('a')]),
      steps: const [AnalysisStep.findingRetainedObjects, AnalysisStep.buildingLeakTraces],
    );

    listener(analyzer).onEvent(heapDump('dump-7'));
    await pumpEventQueue();

    expect(sent.map((event) => event.runtimeType), [
      HeapAnalysisProgressEvent,
      HeapAnalysisProgressEvent,
      HeapAnalysisProgressEvent,
      HeapAnalysisSucceededEvent,
    ]);
    expect(sent.map((event) => event.uniqueId).toSet(), {'dump-7'});
    expect(sent.whereType<HeapAnalysisProgressEvent>().map((event) => event.step), [
      AnalysisStep.findingRetainedObjects,
      AnalysisStep.buildingLeakTraces,
      AnalysisStep.reportingHeapAnalysis,
    ]);
  });

  test('puts the leaks in the hub, and says which were new', () async {
    hub.add(_leak('old'));
    final analyzer = _FakeAnalyzer(
      (dump) => HeapAnalysisSuccess(dump: dump, analysisDuration: Duration.zero, leaks: [_leak('old'), _leak('new')]),
    );

    listener(analyzer).onEvent(heapDump());
    await pumpEventQueue();

    expect(hub.leakHistory.map((leak) => leak.signature), ['old', 'new']);
    final succeeded = sent.whereType<HeapAnalysisSucceededEvent>().single;
    expect(succeeded.newLeakSignatures, {'new'});
    expect(succeeded.heapAnalysis.leaks, hasLength(2));
  });

  test('a failed analysis is announced, and reports nothing', () async {
    final analyzer = _FakeAnalyzer(
      (dump) => HeapAnalysisFailure(dump: dump, analysisDuration: Duration.zero, exception: StateError('vm gone')),
    );

    listener(analyzer).onEvent(heapDump());
    await pumpEventQueue();

    expect(sent.last, isA<HeapAnalysisFailedEvent>());
    expect(hub.leakHistory, isEmpty);
    expect(sent.whereType<HeapAnalysisSucceededEvent>(), isEmpty);
  });

  test('ignores every event but a heap dump', () async {
    final analyzer = _FakeAnalyzer((dump) => HeapAnalysisSuccess(dump: dump, analysisDuration: Duration.zero, leaks: []));
    final background = listener(analyzer);

    background.onEvent(const DumpingHeapEvent('id'));
    background.onEvent(HeapDumpFailedEvent('id', exception: StateError('x'), willRetryLater: false));
    background.onEvent(const HeapAnalysisProgressEvent('id', step: AnalysisStep.buildingLeakTraces, progressPercent: 0.8));
    await pumpEventQueue();

    expect(analyzer.calls, 0);
    expect(sent, isEmpty);
  });

  test('does not hold up the chain of events: onEvent returns before the analysis is done', () async {
    final gate = Completer<void>();
    final analyzer = _FakeAnalyzer(
      (dump) => HeapAnalysisSuccess(dump: dump, analysisDuration: Duration.zero, leaks: []),
      steps: const [AnalysisStep.findingRetainedObjects],
    );
    final background = listener(analyzer, sendEvent: (event) async {
      sent.add(event);
      await gate.future;
    });

    background.onEvent(heapDump());
    await pumpEventQueue();

    expect(sent, hasLength(1), reason: 'the analysis is held up by its first progress listener');
    expect(sent.single, isA<HeapAnalysisProgressEvent>());
    gate.complete();
    await pumpEventQueue();
    expect(sent.last, isA<HeapAnalysisSucceededEvent>());
  });

  test('analyzes each dump separately', () async {
    final analyzer = _FakeAnalyzer((dump) => HeapAnalysisSuccess(dump: dump, analysisDuration: Duration.zero, leaks: []));
    final background = listener(analyzer);

    background.onEvent(heapDump('one'));
    background.onEvent(heapDump('two'));
    await pumpEventQueue();

    expect(analyzer.calls, 2);
    expect(sent.whereType<HeapAnalysisSucceededEvent>().map((event) => event.uniqueId), unorderedEquals(['one', 'two']));
  });
}
