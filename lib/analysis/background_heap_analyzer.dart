import 'dart:async';

import 'package:leak_sentry/analysis/heap_analysis.dart';
import 'package:leak_sentry/analysis/heap_analyzer.dart';
import 'package:leak_sentry/core/leak_report_hub.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';

/// Runs the analysis when a heap is dumped, without holding up the chain of
/// events.
///
/// The analysis runs on the main isolate, in steps that wait on the VM service,
/// so frames can run between them. Moving it to a worker isolate needs the heap
/// snapshot engine, because objects can't be sent to another isolate.
class BackgroundHeapAnalyzer implements LeakSentryEventListener {
  BackgroundHeapAnalyzer({
    required HeapAnalyzer analyzer,
    required LeakReportHub hub,
    required Future<void> Function(LeakSentryEvent event) sendEvent,
  }) : _analyzer = analyzer,
       _hub = hub,
       _sendEvent = sendEvent;

  final HeapAnalyzer _analyzer;
  final LeakReportHub _hub;
  final Future<void> Function(LeakSentryEvent event) _sendEvent;

  @override
  void onEvent(LeakSentryEvent event) {
    if (event is HeapDumpEvent) unawaited(_analyze(event));
  }

  Future<void> _analyze(HeapDumpEvent event) async {
    final analysis = await _analyzer.analyze(
      event.dump,
      onProgress: (step, progressPercent) =>
          _sendEvent(HeapAnalysisProgressEvent(event.uniqueId, step: step, progressPercent: progressPercent)),
    );
    await _sendEvent(
      HeapAnalysisProgressEvent(
        event.uniqueId,
        step: AnalysisStep.reportingHeapAnalysis,
        progressPercent: AnalysisStep.reportingHeapAnalysis.progressPercent,
      ),
    );
    switch (analysis) {
      case HeapAnalysisSuccess():
        final newLeakSignatures = _hub.addAll(analysis.leaks);
        await _sendEvent(
          HeapAnalysisSucceededEvent(event.uniqueId, heapAnalysis: analysis, newLeakSignatures: newLeakSignatures),
        );
      case HeapAnalysisFailure():
        await _sendEvent(HeapAnalysisFailedEvent(event.uniqueId, heapAnalysis: analysis));
    }
  }
}
