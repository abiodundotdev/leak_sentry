import 'dart:async';

import 'package:leak_sentry/analysis/heap_analysis.dart';
import 'package:leak_sentry/core/heap_dumper.dart';

/// Something that happened while LeakSentry looked for leaks.
sealed class LeakSentryEvent {
  const LeakSentryEvent(this.uniqueId);

  /// Identifies a chain of related events. The identifier of the events sent
  /// before [HeapDumpEvent] is replaced right before [HeapDumpEvent] is sent.
  final String uniqueId;
}

/// The heap is about to be dumped.
final class DumpingHeapEvent extends LeakSentryEvent {
  const DumpingHeapEvent(super.uniqueId);
}

/// The heap was dumped.
final class HeapDumpEvent extends LeakSentryEvent {
  const HeapDumpEvent(super.uniqueId, {required this.dump, required this.duration, required this.reason});

  final RetainedObjectsDump dump;
  final Duration duration;
  final String reason;
}

/// The heap could not be dumped.
final class HeapDumpFailedEvent extends LeakSentryEvent {
  const HeapDumpFailedEvent(super.uniqueId, {required this.exception, this.stackTrace, required this.willRetryLater});

  final Object exception;
  final StackTrace? stackTrace;
  final bool willRetryLater;
}

/// The analysis moved on. [progressPercent] is between 0 and 1.
final class HeapAnalysisProgressEvent extends LeakSentryEvent {
  const HeapAnalysisProgressEvent(super.uniqueId, {required this.step, required this.progressPercent});

  final AnalysisStep step;
  final double progressPercent;
}

/// The analysis finished, with a result or with a failure.
sealed class HeapAnalysisDoneEvent<T extends HeapAnalysis> extends LeakSentryEvent {
  const HeapAnalysisDoneEvent(super.uniqueId, {required this.heapAnalysis});

  final T heapAnalysis;
}

final class HeapAnalysisSucceededEvent extends HeapAnalysisDoneEvent<HeapAnalysisSuccess> {
  const HeapAnalysisSucceededEvent(super.uniqueId, {required super.heapAnalysis, required this.newLeakSignatures});

  /// The signatures of the leaks in this analysis that were not reported before.
  final Set<String> newLeakSignatures;
}

final class HeapAnalysisFailedEvent extends HeapAnalysisDoneEvent<HeapAnalysisFailure> {
  const HeapAnalysisFailedEvent(super.uniqueId, {required super.heapAnalysis});
}

/// Listens for [LeakSentryEvent]s.
///
/// The events of one chain (dumping the heap, or analyzing it) are delivered in
/// order, and an asynchronous listener holds up that chain until it completes,
/// for at most ten seconds. That is what lets a listener finish some
/// preparation (such as painting a "dumping" indicator) before the next step
/// starts.
///
/// The two chains are not ordered against each other: the analysis starts when
/// the heap dump event is sent, and runs while the listeners after the analyzer
/// are still hearing that event, so a late listener can hear analysis events
/// before the heap dump event.
abstract interface class LeakSentryEventListener {
  FutureOr<void> onEvent(LeakSentryEvent event);
}
