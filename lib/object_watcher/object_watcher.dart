import 'package:leak_sentry/object_watcher/deletable_object_reporter.dart';
import 'package:leak_sentry/object_watcher/retained_object_tracker.dart';
import 'package:leak_sentry/object_watcher/uptime_clock.dart';

/// Runs a task once the retained delay has passed.
typedef CheckRetainedExecutor = void Function(void Function() task);

/// Watches objects that are expected to become unreachable.
///
/// Watching an object creates a weak reference to it and, once the retained
/// delay has passed, checks whether the collector has cleared that reference.
/// If it hasn't, the object is considered retained and the registered
/// [OnObjectRetainedListener]s are told. No GC runs here, so "retained" is
/// provisional until something forces one.
class ObjectWatcher implements RetainedObjectTracker, DeletableObjectReporter {
  ObjectWatcher({
    required UptimeClock clock,
    required CheckRetainedExecutor checkRetainedExecutor,
    bool Function()? isEnabled,
    StackTrace? Function(Object object)? creationStackOf,
  }) : _clock = clock,
       _checkRetainedExecutor = checkRetainedExecutor,
       _isEnabled = isEnabled ?? _alwaysEnabled,
       _creationStackOf = creationStackOf;

  final UptimeClock _clock;
  final CheckRetainedExecutor _checkRetainedExecutor;
  final bool Function() _isEnabled;
  final StackTrace? Function(Object object)? _creationStackOf;
  final Set<OnObjectRetainedListener> _listeners = {};

  late final WeakReferenceRetainedObjectTracker _tracker = WeakReferenceRetainedObjectTracker(
    clock: _clock,
    onObjectRetained: _notifyObjectRetained,
  );

  static bool _alwaysEnabled() => true;

  @override
  bool get hasRetainedObjects => _tracker.hasRetainedObjects;

  @override
  int get retainedObjectCount => _tracker.retainedObjectCount;

  @override
  bool get hasTrackedObjects => _tracker.hasTrackedObjects;

  @override
  int get trackedObjectCount => _tracker.trackedObjectCount;

  @override
  Duration? get newestRetainedUptime => _tracker.newestRetainedUptime;

  /// Whether any watched object isn't weakly reachable yet, even if it hasn't
  /// been watched long enough to be considered retained.
  bool get hasWatchedObjects => hasTrackedObjects;

  /// The tracker behind this watcher, for the heap dump trigger.
  WeakReferenceRetainedObjectTracker get tracker => _tracker;

  /// The objects currently considered retained.
  ///
  /// Calling this creates strong references to them, which keeps them from
  /// becoming weakly reachable. Use it for logging and release them at once.
  List<Object> get retainedObjects =>
      _tracker.retainedWeakReferences.map((reference) => reference.getAndLeakReferent()).nonNulls.toList();

  void addOnObjectRetainedListener(OnObjectRetainedListener listener) => _listeners.add(listener);

  void removeOnObjectRetainedListener(OnObjectRetainedListener listener) => _listeners.remove(listener);

  /// Expects [watchedObject] to become weakly reachable once the retained
  /// delay has passed. [description] says why, and appears in the report.
  ///
  /// Where this is called is remembered, so that a leak whose creation Flutter
  /// never reported can still say where it was handed over.
  void watch(Object watchedObject, [String description = 'unknown: reason not provided']) {
    if (!_isEnabled()) return;
    _track(watchedObject, description, watchStack: StackTrace.current);
  }

  @override
  TrackedObjectReachability expectDeletionFor(Object target, String reason) {
    if (!_isEnabled()) return const UntrackedObjectReachability();
    return _track(target, reason);
  }

  RetainTrigger _track(Object target, String reason, {StackTrace? watchStack}) {
    final trigger = _tracker.expectDeletionOnTriggerFor(
      target,
      reason,
      creationStack: _creationStackOf?.call(target),
      watchStack: watchStack,
    );
    _checkRetainedExecutor(trigger.markRetainedIfStronglyReachable);
    return trigger;
  }

  /// Forgets every object watched at or before [uptime] on the clock this
  /// watcher was built with.
  void clearObjectsWatchedBefore(Duration uptime) => clearObjectsTrackedBefore(uptime);

  /// Forgets every watched object.
  void clearWatchedObjects() => clearAllObjectsTracked();

  @override
  void clearObjectsTrackedBefore(Duration uptime) => _tracker.clearObjectsTrackedBefore(uptime);

  @override
  void clearAllObjectsTracked() => _tracker.clearAllObjectsTracked();

  void _notifyObjectRetained() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }
}
