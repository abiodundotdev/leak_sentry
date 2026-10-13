/// The wording of the notices and log lines about retained objects, heap dumps and
/// their analysis.
abstract final class LeakSentryStrings {
  static const String notInstalled = 'LeakSentry is not installed.';

  static const String heapDumpEnabled = 'LeakSentry is running and ready to detect memory leaks.';

  static String heapDumpDisabled(String reason) => 'LeakSentry is currently disabled: $reason.';

  static const String heapDumpDisabledByApp = 'LeakSentryConfig.dumpHeap is set to false';

  static const String heapDumpDisabledFromUi = 'heap dumping disabled from the LeakSentry Settings screen';

  static String heapDumpDisabledRunningTests(String testEnvironment) =>
      'running in a test environment ($testEnvironment), so heap dumping is turned off';

  static const String noRetainedObjectTitle = 'All retained objects were garbage collected';

  static const String noRetainedObjectContent = 'Tap to dismiss';

  static const String retainedDumpFailed = 'Failed to dump heap';

  static const String retainedDumpWait = 'Last heap dump was less than a minute ago';

  static String retainedTitle(int objectCount) => '$objectCount retained objects, tap to dump heap';

  static String retainedVisible(int threshold) => 'App visible, waiting until $threshold retained objects';

  static const String dumpingHeap = 'Dumping Heap';

  static const String analyzingHeapDump = 'Analyzing Heap Dump';

  static const String toastHeapDump = 'LeakSentry is dumping memory to investigate leaks.';

  static const String analysisFailed = 'Heap analysis failed';

  static String analysisSuccess(int retainedObjects, int distinctLeaks, int newLeaks) =>
      'Found $retainedObjects retained objects grouped as $distinctLeaks distinct leaks ($newLeaks new)';
}
