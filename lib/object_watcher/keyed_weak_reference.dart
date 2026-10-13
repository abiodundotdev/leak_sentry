/// A weak reference to a watched object, plus what the tracker needs to know
/// about it.
///
/// Reading a weak reference creates a strong reference on the stack, and the
/// collector may then treat the object as reachable for the rest of its cycle,
/// so there is no `target` getter here. Use [isCleared] to ask whether the
/// object is gone, and [getAndLeakReferent] only for a short synchronous use.
class KeyedWeakReference {
  KeyedWeakReference(
    Object referent, {
    required this.key,
    required this.description,
    required this.watchUptime,
    required this.watchedAt,
    this.creationStack,
    this.watchStack,
  }) : _reference = WeakReference<Object>(referent),
       type = referent.runtimeType,
       identityHash = identityHashCode(referent);

  /// Unique within one tracker.
  final String key;

  /// Why the object was expected to be collected.
  final String description;

  /// The runtime type of the watched object, captured up front.
  final Type type;

  /// `identityHashCode` of the watched object. A heap snapshot records the
  /// same value, so it identifies the object there without referencing it.
  final int identityHash;

  /// When the object was watched, on the tracker's [UptimeClock].
  final Duration watchUptime;

  /// When the object was watched, as wall-clock time for display.
  final DateTime watchedAt;

  /// The stack trace captured when the object was created, if it was seen.
  final StackTrace? creationStack;

  /// The stack trace captured when the object was handed to
  /// `ObjectWatcher.watch`. Only a manual `watch` captures one: the default
  /// watchers have a creation stack instead.
  final StackTrace? watchStack;

  final WeakReference<Object> _reference;

  /// When the object was considered retained, or null if it hasn't been yet.
  Duration? retainedUptime;

  bool get retained => retainedUptime != null;

  /// Whether the garbage collector has already collected the object, having
  /// found it unreachable. It never keeps a reference to the object.
  bool get isCleared => _reference.target == null;

  /// The watched object, or null. Calling this creates a strong reference, so
  /// use it only for a short synchronous read (for example, asking the VM for
  /// the object's id) and never keep the result across an `await`.
  Object? getAndLeakReferent() => _reference.target;
}

/// What is known about a retained object, captured without holding the
/// object itself.
class RetainedObjectSnapshot {
  const RetainedObjectSnapshot({
    required this.key,
    required this.description,
    required this.type,
    required this.identityHash,
    required this.watchUptime,
    required this.retainedUptime,
    required this.watchedAt,
    this.creationStack,
    this.watchStack,
    this.vmObjectIdResolver,
    this.collectedProbe,
  });

  final String key;
  final String description;
  final Type type;
  final int identityHash;
  final Duration watchUptime;
  final Duration retainedUptime;
  final DateTime watchedAt;
  final StackTrace? creationStack;

  /// Where the object was handed to `ObjectWatcher.watch`, when it was.
  final StackTrace? watchStack;

  /// Looks up the VM service id of the object, or null when the object is gone.
  final String? Function()? vmObjectIdResolver;

  /// Tells whether the object has been collected since the snapshot was taken.
  final bool Function()? collectedProbe;

  /// Whether the object has been collected since the snapshot was taken, which
  /// means whatever retained it let go. False when that can't be known.
  bool get isCollected => collectedProbe?.call() ?? false;

  /// The VM service id of the object, if a VM service is available and the
  /// object is still alive.
  ///
  /// This is a method, not a field captured with the snapshot, because asking
  /// the VM for an id pins the object in the VM's object id ring (a few
  /// thousand entries) so that it can't be collected. Only the objects whose
  /// retaining path is going to be looked up should pay for that.
  String? resolveVmObjectId() => vmObjectIdResolver?.call();
}
