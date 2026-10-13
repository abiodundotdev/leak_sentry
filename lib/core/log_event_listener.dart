import 'package:leak_sentry/core/heap_dump_policy.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';
import 'package:leak_sentry/core/leak_sentry_log.dart';

/// Writes the events that matter to the log.
class LogEventListener implements LeakSentryEventListener {
  const LogEventListener();

  @override
  void onEvent(LeakSentryEvent event) {
    switch (event) {
      case HeapDumpFailedEvent():
        if (event.willRetryLater) {
          LeakSentryLog.d(
            () => 'Failed to dump heap, will retry in ${HeapDumpPolicy.waitAfterDumpFailed.inMilliseconds} ms',
            error: event.exception,
            stackTrace: event.stackTrace,
          );
        } else {
          LeakSentryLog.d(
            () => 'Failed to dump heap, will not automatically retry',
            error: event.exception,
            stackTrace: event.stackTrace,
          );
        }
      case HeapAnalysisProgressEvent():
        final percent = (event.progressPercent * 100).toInt();
        LeakSentryLog.d(() => 'Analysis in progress, $percent% done, working on ${event.step.humanReadableName}');
      case HeapAnalysisDoneEvent():
        LeakSentryLog.d(() => '\n${event.heapAnalysis}');
      case DumpingHeapEvent() || HeapDumpEvent():
        break;
    }
  }
}
