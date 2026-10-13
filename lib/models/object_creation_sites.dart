/// Creation stack traces of objects that are alive and not yet disposed, so
/// a stack captured at creation can be attached to the entry made when the
/// object is watched later, at disposal.
///
/// Keyed by [identityHashCode] with a [WeakReference] rather than an
/// [Expando], so that entries whose object was collected can be enumerated and
/// dropped. A [StackTrace] holds code offsets, not the object, so storing one
/// can't keep the object alive either.
class ObjectCreationSites {
  /// [hashOf] only exists so tests can force hash collisions.
  ObjectCreationSites({int Function(Object object) hashOf = identityHashCode}) : _hashOf = hashOf;

  final int Function(Object object) _hashOf;
  final Map<int, List<_Entry>> _byHash = {};

  /// Number of objects with a stored creation stack.
  int get length => _byHash.values.fold(0, (total, bucket) => total + bucket.length);

  /// Stores [stack] as the creation stack of [object]. Keeps the first one
  /// if [object] already has one.
  void record(Object object, StackTrace stack) {
    final bucket = _byHash.putIfAbsent(_hashOf(object), () => <_Entry>[]);
    if (bucket.any((entry) => identical(entry.ref.target, object))) return;
    bucket.add(_Entry(WeakReference<Object>(object), stack));
  }

  /// Removes and returns the creation stack of [object], or `null` if none
  /// was recorded.
  StackTrace? take(Object object) {
    final hash = _hashOf(object);
    final bucket = _byHash[hash];
    if (bucket == null) return null;
    final index = bucket.indexWhere((entry) => identical(entry.ref.target, object));
    if (index < 0) return null;
    final entry = bucket.removeAt(index);
    if (bucket.isEmpty) _byHash.remove(hash);
    return entry.stack;
  }

  /// Drops entries whose object has been garbage collected without ever
  /// being disposed.
  void pruneCollected() {
    _byHash.removeWhere((_, bucket) {
      bucket.removeWhere((entry) => entry.ref.target == null);
      return bucket.isEmpty;
    });
  }

  void clear() => _byHash.clear();
}

class _Entry {
  _Entry(this.ref, this.stack);

  final WeakReference<Object> ref;
  final StackTrace stack;
}
