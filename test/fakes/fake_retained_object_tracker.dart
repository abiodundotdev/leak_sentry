import 'package:leak_sentry/object_watcher/retained_object_tracker.dart';

/// A [RetainedObjectTracker] whose counts a test sets directly.
class FakeRetainedObjectTracker implements RetainedObjectTracker {
  int retained = 0;
  int tracked = 0;
  Duration? newestRetained;

  /// Whether clearing objects (which happens after every heap dump) also
  /// forgets the retained ones, as the real tracker does.
  bool clearingForgetsRetained = true;

  final List<Duration> clearedBefore = [];
  int clearAllCalls = 0;

  @override
  int get retainedObjectCount => retained;

  @override
  bool get hasRetainedObjects => retained > 0;

  @override
  int get trackedObjectCount => tracked;

  @override
  bool get hasTrackedObjects => tracked > 0;

  @override
  Duration? get newestRetainedUptime => newestRetained;

  @override
  void clearObjectsTrackedBefore(Duration uptime) {
    clearedBefore.add(uptime);
    if (clearingForgetsRetained) {
      retained = 0;
      newestRetained = null;
    }
  }

  @override
  void clearAllObjectsTracked() {
    clearAllCalls++;
    retained = 0;
    tracked = 0;
    newestRetained = null;
  }
}
