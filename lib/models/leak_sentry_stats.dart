/// Cumulative counters for what leak detection costs the app, so its overhead
/// can be measured instead of guessed. Written by LeakSentry only; read them
/// through `LeakSentry.stats`.
class LeakSentryStats {
  /// `ObjectCreated` events whose stack trace was captured, and the total time
  /// spent handling them.
  int creationEvents = 0;
  int creationMicros = 0;

  /// `ObjectDisposed` events handled, and the total time spent handling them.
  int disposalEvents = 0;
  int disposalMicros = 0;

  /// Retained-object checks run, and the total time they took (including time
  /// spent waiting for a forced GC).
  int retainedChecks = 0;
  int retainedCheckMicros = 0;

  /// Forced GCs that were confirmed, how long they took in total, and how many
  /// could not be confirmed.
  int forcedGcs = 0;
  int forcedGcMicros = 0;
  int forcedGcFailures = 0;

  /// Checks that skipped the forced GC because the last one had already given
  /// every retained object the chance to be collected.
  int forcedGcsSkipped = 0;

  /// Heap dumps taken, and how many failed.
  int heapDumps = 0;
  int heapDumpFailures = 0;

  /// Analyses run, and the total time they took.
  int analyses = 0;
  int analysisMicros = 0;

  /// Retaining-path lookups made, and the total time they took.
  int retainingPathLookups = 0;
  int retainingPathMicros = 0;

  /// Leaks merged into an existing report without a retaining-path lookup.
  int duplicatesSkipped = 0;

  @override
  String toString() =>
      'LeakSentryStats('
      'creationEvents: $creationEvents (${creationMicros}us), '
      'disposalEvents: $disposalEvents (${disposalMicros}us), '
      'retainedChecks: $retainedChecks (${retainedCheckMicros}us), '
      'forcedGcs: $forcedGcs (${forcedGcMicros}us, $forcedGcFailures unconfirmed, $forcedGcsSkipped skipped), '
      'heapDumps: $heapDumps ($heapDumpFailures failed), '
      'analyses: $analyses (${analysisMicros}us), '
      'retainingPathLookups: $retainingPathLookups (${retainingPathMicros}us), '
      'duplicatesSkipped: $duplicatesSkipped)';
}
