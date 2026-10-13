/// The timing constants and defaults for checking retained objects and dumping
/// the heap.
abstract final class HeapDumpPolicy {
  /// How long to wait before retrying after a heap dump failed.
  static const Duration waitAfterDumpFailed = Duration(seconds: 5);

  /// How often to recheck while fewer objects are retained than the visible
  /// threshold.
  static const Duration waitForObjectThreshold = Duration(seconds: 2);

  /// How long the "no retained objects" notice stays up.
  static const Duration dismissNoRetainedObjectNotice = Duration(seconds: 30);

  /// The least time between two heap dumps. Dumping freezes the app, so it
  /// must not happen back to back.
  static const Duration waitBetweenHeapDumps = Duration(seconds: 60);

  /// How long a forced GC is trusted to have settled the retained count when
  /// no new object has become retained since. After this, the next check runs
  /// another one, so an object released in the meantime is noticed.
  ///
  /// A Dart GC pauses the isolate that runs the app, so repeating it every two
  /// seconds for the same retained objects would cost a frame hitch each time
  /// for nothing.
  static const Duration staleCountRefreshInterval = Duration(seconds: 60);

  /// The longest a check waits for a forced GC. A GC that never answers would
  /// otherwise hold up every check after it.
  static const Duration maxGcWait = Duration(seconds: 30);

  /// The longest a check waits for the heap to be dumped.
  static const Duration maxDumpWait = Duration(seconds: 30);

  /// The longest an event listener may hold up the chain of events. This is
  /// long enough for a listener that waits for a frame, for example to show
  /// something before the app freezes for a heap dump.
  static const Duration maxListenerWait = Duration(seconds: 10);

  /// The longest `LeakSentry.dumpHeap` waits for the analysis of the heap it
  /// dumped.
  static const Duration maxAnalysisWait = Duration(seconds: 60);

  /// The default time an object has to become collectable before it counts as
  /// retained.
  static const Duration defaultRetainedDelay = Duration(seconds: 5);

  /// The default number of retained objects that has to build up while the app
  /// is visible before the heap is dumped.
  static const int defaultRetainedVisibleThreshold = 5;
}
