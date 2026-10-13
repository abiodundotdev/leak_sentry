/// A monotonic clock: how long the process has been running.
///
/// Elapsed time is measured with it because the wall clock can jump. Only
/// differences between two readings mean anything.
typedef UptimeClock = Duration Function();

final Stopwatch _processStopwatch = Stopwatch()..start();

/// The default [UptimeClock], backed by a process-wide [Stopwatch].
Duration systemUptime() => _processStopwatch.elapsed;
