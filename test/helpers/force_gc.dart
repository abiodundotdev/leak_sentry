import 'dart:async';
import 'dart:developer' show reachabilityBarrier;

/// Forces garbage collection, so a test can tell whether an object is still
/// reachable.
///
/// Allocates memory (yielding to the event loop in between) until the VM's
/// reachability barrier has advanced by [fullGcCycles]. The barrier also
/// advances when concurrent marking starts, so a few cycles are needed before
/// an object that just became unreachable is certain to have been collected.
/// Throws if that takes longer than [timeout], so a test fails instead of
/// hanging. Doesn't work on web.
Future<void> forceGc({int fullGcCycles = 3, Duration timeout = const Duration(seconds: 10)}) async {
  final stopwatch = Stopwatch()..start();
  final target = reachabilityBarrier + fullGcCycles;
  final garbage = <List<int>>[];
  while (reachabilityBarrier < target) {
    if (stopwatch.elapsed > timeout) throw TimeoutException('forceGc timed out', timeout);
    await Future<void>.delayed(Duration.zero);
    garbage.add(List<int>.generate(30000, (n) => n));
    if (garbage.length > 100) garbage.removeAt(0);
  }
}
