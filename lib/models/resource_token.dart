/// A handle returned by tracking a resource for "was it closed before it
/// was garbage collected?" detection.
///
/// Deliberately holds no reference — direct or via a captured closure — to
/// the resource it was created for. It carries only a label, a captured
/// stack trace, and a plain boolean flag, which is what makes it safe to
/// use as a [Finalizer] token: anything else (e.g. a closure like
/// `() => resource.isClosed`) would keep the resource reachable forever
/// through the finalizer's own bookkeeping, so it would never be collected
/// and the leak would never be reported.
class ResourceToken {
  ResourceToken(this.label, {required this.type}) : acquiredAt = StackTrace.current, createdAt = DateTime.now();

  /// A human-readable label identifying the tracked resource (its type
  /// name, or a caller-supplied description).
  final String label;

  /// Runtime type of the tracked resource, captured up front since the
  /// resource itself is inaccessible from a [Finalizer] callback.
  final Type type;

  /// When the resource was created / tracking began.
  final DateTime createdAt;

  /// Where the resource was created, as a stack trace captured at tracking
  /// time, so a reported leak is actionable even without a retaining path.
  final StackTrace acquiredAt;

  bool _closed = false;

  /// Whether [markClosed] has been called.
  bool get isClosed => _closed;

  /// Call this from the resource's real close/dispose path. If this is
  /// never called before the tracked resource is garbage collected, a
  /// leak is reported.
  void markClosed() => _closed = true;
}
