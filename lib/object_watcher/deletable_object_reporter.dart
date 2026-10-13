import 'package:leak_sentry/object_watcher/delayed_executor.dart';

/// What is known about a tracked object's reachability.
abstract interface class TrackedObjectReachability {
  /// Whether the tracked object is still strongly reachable, that is, the
  /// collector hasn't collected it.
  bool get isStronglyReachable;

  /// Whether the object was marked retained and is still strongly reachable.
  bool get isRetained;
}

extension TrackedObjectReachabilityDeletion on TrackedObjectReachability {
  /// Whether the object is eligible for automatic garbage collection.
  bool get isDeletable => !isStronglyReachable;
}

/// Reports objects that are expected to be garbage collected soon.
abstract interface class DeletableObjectReporter {
  /// Starts tracking [target], which should stop being strongly reachable
  /// soon. If it stays reachable, it is considered retained. When that is
  /// decided is up to the implementation.
  ///
  /// [reason] says why the object should be gone, for example
  /// "MyPresenter received the dispose() callback".
  TrackedObjectReachability expectDeletionFor(Object target, String reason);
}

/// Passes [DeletableObjectReporter.expectDeletionFor] calls through only when
/// [apply] returns true for an instance of [T]. Objects of any other type are
/// always passed on.
extension FilteringDeletableObjectReporter on DeletableObjectReporter {
  DeletableObjectReporter filteringInstances<T extends Object>(bool Function(T target) apply) =>
      _FilteringReporter<T>(this, apply);
}

class _FilteringReporter<T extends Object> implements DeletableObjectReporter {
  _FilteringReporter(this._delegate, this._apply);

  final DeletableObjectReporter _delegate;
  final bool Function(T target) _apply;

  @override
  TrackedObjectReachability expectDeletionFor(Object target, String reason) {
    if (target is! T || _apply(target)) return _delegate.expectDeletionFor(target, reason);
    return const UntrackedObjectReachability();
  }
}

/// The reachability of an object nobody tracks: it never counts as retained.
class UntrackedObjectReachability implements TrackedObjectReachability {
  const UntrackedObjectReachability();

  @override
  bool get isStronglyReachable => false;

  @override
  bool get isRetained => false;
}

/// A handle to one tracked object that can mark it retained. Holds the
/// object's key, never the object.
abstract interface class RetainTrigger implements TrackedObjectReachability {
  /// Marks the tracked object retained if it is still strongly reachable.
  void markRetainedIfStronglyReachable();
}

/// Tracks the deletion of target objects, marking them retained on trigger.
abstract interface class TriggeredDeletableObjectReporter {
  /// Starts tracking [target], which should be eligible for garbage collection
  /// by the time [RetainTrigger.markRetainedIfStronglyReachable] is called on
  /// the returned trigger.
  RetainTrigger expectDeletionOnTriggerFor(Object target, String reason);
}

/// Like [DeletableObjectReporter.expectDeletionFor] with a delay of the
/// caller's choosing.
class DelayedDeletableObjectReporter {
  DelayedDeletableObjectReporter({
    required TriggeredDeletableObjectReporter deletableObjectReporter,
    required DelayedExecutor delayedExecutor,
  }) : _reporter = deletableObjectReporter,
       _executor = delayedExecutor;

  final TriggeredDeletableObjectReporter _reporter;
  final DelayedExecutor _executor;

  /// [delayUptime] is how long to wait before [target] is considered retained.
  /// It must be long enough for the collector to run and update reachability.
  TrackedObjectReachability expectDelayedDeletionFor(Object target, String reason, Duration delayUptime) {
    final trigger = _reporter.expectDeletionOnTriggerFor(target, reason);
    _executor.executeWithDelay(delayUptime, trigger.markRetainedIfStronglyReachable);
    return trigger;
  }
}

/// A [DeletableObjectReporter] that always waits [defaultDelay].
class DefaultDelayDeletableObjectReporter implements DeletableObjectReporter {
  DefaultDelayDeletableObjectReporter({required this.defaultDelay, required DelayedDeletableObjectReporter delayedReporter})
    : _delayedReporter = delayedReporter;

  /// A delay long enough for the collector to run and update reachability.
  final Duration defaultDelay;

  final DelayedDeletableObjectReporter _delayedReporter;

  @override
  TrackedObjectReachability expectDeletionFor(Object target, String reason) =>
      _delayedReporter.expectDelayedDeletionFor(target, reason, defaultDelay);
}
