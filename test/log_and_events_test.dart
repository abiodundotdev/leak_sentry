import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/heap_analysis.dart';
import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';
import 'package:leak_sentry/core/leak_sentry_log.dart';
import 'package:leak_sentry/core/leak_sentry_strings.dart';
import 'package:leak_sentry/core/log_event_listener.dart';
import 'package:leak_sentry/object_watcher/scheduler.dart';
import 'package:leak_sentry/object_watcher/uptime_clock.dart';

import 'helpers/capture_log.dart';

const _dump = RetainedObjectsDump(objects: [], dumpUptime: Duration(seconds: 3));

void main() {
  group('LeakSentryLog', () {
    test('is silent until a logger is set, and never builds the message then', () {
      final previous = LeakSentryLog.logger;
      addTearDown(() => LeakSentryLog.logger = previous);
      LeakSentryLog.logger = null;
      var built = 0;

      LeakSentryLog.d(() {
        built++;
        return 'expensive';
      });

      expect(built, 0);
    });

    test('leaves out the verbose lines unless asked, and never builds them', () {
      final log = captureLog();
      var built = 0;

      LeakSentryLog.v(() {
        built++;
        return 'one per watched object';
      });
      expect(log.lines, isEmpty);
      expect(built, 0);

      LeakSentryLog.verbose = true;
      LeakSentryLog.v(() => 'one per watched object');
      expect(log.lines, ['one per watched object']);
    });

    test('hands the message and the error to the logger', () {
      final log = captureLog();
      final error = StateError('boom');

      LeakSentryLog.d(() => 'something happened', error: error);

      expect(log.lines, ['something happened']);
      expect(log.errors, [error]);
    });

    test('the console logger prints with a LeakSentry prefix, and the error and stack when given', () {
      final original = debugPrint;
      addTearDown(() => debugPrint = original);
      final printed = <String>[];
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');

      const ConsoleLeakSentryLogger().d('hello');
      expect(printed, ['LeakSentry: hello']);

      printed.clear();
      const ConsoleLeakSentryLogger().d('failed', StateError('boom'), StackTrace.fromString('#0 here'));
      expect(printed, ['LeakSentry: failed', 'LeakSentry: Bad state: boom', '#0 here']);
    });
  });

  group('LogEventListener', () {
    late CapturingLogger log;

    setUp(() => log = captureLog());

    test('says a failed dump will be retried, and when', () {
      const LogEventListener().onEvent(
        HeapDumpFailedEvent('id', exception: StateError('no space'), willRetryLater: true),
      );

      expect(log.lines, ['Failed to dump heap, will retry in 5000 ms']);
      expect(log.errors.single, isA<StateError>());
    });

    test('says a failed dump will not be retried', () {
      const LogEventListener().onEvent(
        HeapDumpFailedEvent('id', exception: StateError('no space'), willRetryLater: false),
      );

      expect(log.lines, ['Failed to dump heap, will not automatically retry']);
    });

    test('reports analysis progress as a percentage and a step name', () {
      const LogEventListener().onEvent(
        HeapAnalysisProgressEvent(
          'id',
          step: AnalysisStep.findingPathsToRetainedObjects,
          progressPercent: AnalysisStep.findingPathsToRetainedObjects.progressPercent,
        ),
      );

      expect(log.lines, ['Analysis in progress, 30% done, working on Finding paths to retained objects']);
    });

    test('prints the finished analysis', () {
      const analysis = HeapAnalysisSuccess(dump: _dump, analysisDuration: Duration(milliseconds: 4), leaks: []);

      const LogEventListener().onEvent(const HeapAnalysisSucceededEvent('id', heapAnalysis: analysis, newLeakSignatures: {}));

      expect(log.lines.single, startsWith('\n====================================\nHEAP ANALYSIS RESULT'));
    });

    test('prints a failed analysis too', () {
      final analysis = HeapAnalysisFailure(dump: _dump, analysisDuration: Duration.zero, exception: StateError('vm gone'));

      const LogEventListener().onEvent(HeapAnalysisFailedEvent('id', heapAnalysis: analysis));

      expect(log.lines.single, contains('HEAP ANALYSIS FAILED'));
      expect(log.lines.single, contains('vm gone'));
    });

    test('has nothing to say about a heap being dumped', () {
      const LogEventListener().onEvent(const DumpingHeapEvent('id'));
      const LogEventListener().onEvent(const HeapDumpEvent('id', dump: _dump, duration: Duration.zero, reason: 'r'));

      expect(log.lines, isEmpty);
    });
  });

  group('the texts', () {
    test('keep their exact wording', () {
      expect(LeakSentryStrings.retainedTitle(3), '3 retained objects, tap to dump heap');
      expect(LeakSentryStrings.retainedVisible(5), 'App visible, waiting until 5 retained objects');
      expect(LeakSentryStrings.noRetainedObjectTitle, 'All retained objects were garbage collected');
      expect(LeakSentryStrings.retainedDumpWait, 'Last heap dump was less than a minute ago');
      expect(LeakSentryStrings.retainedDumpFailed, 'Failed to dump heap');
      expect(LeakSentryStrings.analysisSuccess(4, 2, 1), 'Found 4 retained objects grouped as 2 distinct leaks (1 new)');
      expect(LeakSentryStrings.heapDumpDisabled('why'), 'LeakSentry is currently disabled: why.');
      expect(LeakSentryStrings.toastHeapDump, 'LeakSentry is dumping memory to investigate leaks.');
    });
  });

  group('the clock and the scheduler', () {
    test('uptime only moves forward', () async {
      final first = systemUptime();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final second = systemUptime();

      expect(second, greaterThan(first));
      expect(first, greaterThanOrEqualTo(Duration.zero));
    });

    test('a timer scheduler runs the task after the delay', () async {
      var ran = false;

      const TimerScheduler().postDelayed(const Duration(milliseconds: 10), () => ran = true);
      expect(ran, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(ran, isTrue);
    });

    test('a cancelled timer task never runs', () async {
      var ran = false;

      const TimerScheduler().postDelayed(const Duration(milliseconds: 10), () => ran = true).cancel();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(ran, isFalse);
    });
  });
}
