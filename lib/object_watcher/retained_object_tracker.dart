import 'package:leak_sentry/core/leak_sentry_log.dart';
import 'package:leak_sentry/models/object_finalizer.dart';
import 'package:leak_sentry/object_watcher/deletable_object_reporter.dart';
import 'package:leak_sentry/object_watcher/keyed_weak_reference.dart';
import 'package:leak_sentry/object_watcher/uptime_clock.dart';

/// Called each time a tracked object is marked retained.
typedef OnObjectRetainedListener = void Function();

/// Tracks objects that are expected to be garbage collected, and which of them
/// are retained.
///
/// A retained object is expected to be deleted but stays strongly reachable.
/// Once a tracked object becomes weakly reachable the tracker forgets it.
abstract interface class RetainedObjectTracker {
  /// Whether any tracked object is currently retained.
  bool get hasRetainedObjects;

  /// The number of tracked objects that were still there when their delay ended.
  int get retainedObjectCount;

  /// Whether any object is tracked that isn't weakly reachable yet, even if it
  /// hasn't been tracked long enough to be considered retained.
  bool get hasTrackedObjects;

  /// The number of tracked objects that aren't weakly reachable yet.
  int get trackedObjectCount;

  /// When the most recently retained object was marked retained, or null.
  ///
  /// A forced GC that started after this moment has already given every
  /// retained object the chance to be collected, so another one changes
  /// nothing.
  Duration? get newestRetainedUptime;

  /// Forgets every object that was tracked at or before [uptime], retained or
  /// not. Called after a heap dump so a reported object is never reported
  /// again.
  void clearObjectsTrackedBefore(Duration uptime);

  /// Forgets every tracked object.
  void clearAllObjectsTracked();
}

/// The [RetainedObjectTracker] built on [WeakReference].
///
/// Whether an object is gone is read from its [WeakReference]: a target that is
/// null was cleared by the collector, so every count discards cleared references
/// first. A finalizer also removes them some time after the collection, which
/// keeps the map small between counts without scanning it on every `watch`.
///
/// [finalizerFactory] builds that finalizer, given the callback it must call
/// with a key. Tests pass one that never fires, to check that the counts alone
/// are right about collected objects.
class WeakReferenceRetainedObjectTracker implements RetainedObjectTracker, TriggeredDeletableObjectReporter {
  WeakReferenceRetainedObjectTracker({
    required UptimeClock clock,
    required OnObjectRetainedListener onObjectRetained,
    ObjectFinalizer<String> Function(void Function(String key) onCollected)? finalizerFactory,
  }) : _clock = clock,
       _onObjectRetained = onObjectRetained {
    _finalizer = (finalizerFactory ?? RealObjectFinalizer<String>.new)((key) => _watched.remove(key));
  }

  final UptimeClock _clock;
  final OnObjectRetainedListener _onObjectRetained;
  final Map<String, KeyedWeakReference> _watched = {};
  int _nextKey = 0;
  late final ObjectFinalizer<String> _finalizer;

  /// The references of tracked objects that aren't weakly reachable yet.
  ///
  /// Don't read the objects behind them with [KeyedWeakReference.getAndLeakReferent]
  /// unless you must: a strong reference on the stack keeps an object alive.
  List<KeyedWeakReference> get trackedWeakReferences {
    _removeCleared();
    return _watched.values.toList(growable: false);
  }

  /// The subset of [trackedWeakReferences] that was marked retained.
  List<KeyedWeakReference> get retainedWeakReferences {
    _removeCleared();
    return [
      for (final reference in _watched.values)
        if (reference.retained) reference,
    ];
  }

  @override
  bool get hasRetainedObjects => retainedObjectCount > 0;

  @override
  int get retainedObjectCount {
    _removeCleared();
    var count = 0;
    for (final reference in _watched.values) {
      if (reference.retained) count++;
    }
    return count;
  }

  @override
  bool get hasTrackedObjects => trackedObjectCount > 0;

  @override
  int get trackedObjectCount {
    _removeCleared();
    return _watched.length;
  }

  @override
  Duration? get newestRetainedUptime {
    _removeCleared();
    Duration? newest;
    for (final reference in _watched.values) {
      final retainedUptime = reference.retainedUptime;
      if (retainedUptime != null && (newest == null || retainedUptime > newest)) newest = retainedUptime;
    }
    return newest;
  }

  /// Starts tracking [target]. [creationStack] is where it was created, if
  /// that is known, and [watchStack] is where it was handed over to be watched.
  @override
  RetainTrigger expectDeletionOnTriggerFor(
    Object target,
    String reason, {
    StackTrace? creationStack,
    StackTrace? watchStack,
  }) {
    final key = 'k${(_nextKey++).toRadixString(36)}';
    final reference = KeyedWeakReference(
      target,
      key: key,
      description: reason,
      watchUptime: _clock(),
      watchedAt: DateTime.now(),
      creationStack: creationStack,
      watchStack: watchStack,
    );
    LeakSentryLog.v(
      () => 'Watching instance of ${reference.type}${reason.isNotEmpty ? ' ($reason)' : ''} with key $key',
    );
    _watched[key] = reference;
    _finalizer.attach(target, key);
    return _KeyTrigger(this, key);
  }

  @override
  void clearObjectsTrackedBefore(Duration uptime) {
    _watched.removeWhere((_, reference) => reference.watchUptime <= uptime);
  }

  @override
  void clearAllObjectsTracked() => _watched.clear();

  /// Captures what is known about each retained object that is still alive,
  /// without holding any of them.
  ///
  /// [objectIdOf] gives an object's VM id. It is not called here: each snapshot
  /// can ask for it later through [RetainedObjectSnapshot.resolveVmObjectId],
  /// which reads the object from its weak reference at that moment, because a
  /// VM id pins the object and only a few of the snapshots need one.
  List<RetainedObjectSnapshot> snapshotRetainedObjects({String? Function(Object object)? objectIdOf}) {
    _removeCleared();
    final snapshots = <RetainedObjectSnapshot>[];
    for (final reference in _watched.values) {
      final retainedUptime = reference.retainedUptime;
      if (retainedUptime == null || reference.isCleared) continue;
      snapshots.add(
        RetainedObjectSnapshot(
          key: reference.key,
          description: reference.description,
          type: reference.type,
          identityHash: reference.identityHash,
          watchUptime: reference.watchUptime,
          retainedUptime: retainedUptime,
          watchedAt: reference.watchedAt,
          creationStack: reference.creationStack,
          watchStack: reference.watchStack,
          vmObjectIdResolver: objectIdOf == null
              ? null
              : () {
                  final target = reference.getAndLeakReferent();
                  return target == null ? null : objectIdOf(target);
                },
          collectedProbe: () => reference.isCleared,
        ),
      );
    }
    return snapshots;
  }

  void _moveToRetained(String key) {
    final reference = _liveReference(key);
    if (reference == null) return;
    reference.retainedUptime = _clock();
    _onObjectRetained();
  }

  /// The reference for [key] if its object hasn't been collected. Checks one
  /// entry, so a thousand objects reaching their delay together don't each
  /// scan the whole map.
  KeyedWeakReference? _liveReference(String key) {
    final reference = _watched[key];
    if (reference == null) return null;
    if (reference.isCleared) {
      _watched.remove(key);
      return null;
    }
    return reference;
  }

  void _removeCleared() => _watched.removeWhere((_, reference) => reference.isCleared);
}

class _KeyTrigger implements RetainTrigger {
  _KeyTrigger(this._tracker, this._key);

  final WeakReferenceRetainedObjectTracker _tracker;
  final String _key;

  @override
  bool get isStronglyReachable => _tracker._liveReference(_key) != null;

  @override
  bool get isRetained => _tracker._liveReference(_key)?.retained ?? false;

  @override
  void markRetainedIfStronglyReachable() => _tracker._moveToRetained(_key);
}
