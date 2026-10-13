/// Abstraction over [Finalizer], so tests can inject a deterministic fake
/// instead of depending on real, non-deterministic GC timing.
///
/// Per [Finalizer]'s contract, [value] and the `detach` argument "do not
/// count towards those objects being accessible to the program" — so
/// implementations must never let [token] hold a strong reference back to
/// [value] (directly, or via a captured closure), or [value] can never
/// become unreachable and the finalizer will never fire.
abstract class ObjectFinalizer<T extends Object> {
  /// Requests that this finalizer's callback run some time after [value]
  /// becomes inaccessible, with [token] as its argument.
  void attach(Object value, T token, {Object? detach});

  /// Cancels a pending finalization previously attached with this
  /// [detachToken].
  void detach(Object detachToken);
}

/// The real, GC-backed [ObjectFinalizer], wrapping [Finalizer].
class RealObjectFinalizer<T extends Object> implements ObjectFinalizer<T> {
  RealObjectFinalizer(void Function(T token) callback) : _finalizer = Finalizer<T>(callback);

  final Finalizer<T> _finalizer;

  @override
  void attach(Object value, T token, {Object? detach}) => _finalizer.attach(value, token, detach: detach);

  @override
  void detach(Object detachToken) => _finalizer.detach(detachToken);
}
