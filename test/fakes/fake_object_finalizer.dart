import 'package:leak_sentry/models/object_finalizer.dart';

/// A deterministic, manually-triggered [ObjectFinalizer] for tests.
///
/// Real GC/[Finalizer] timing can't be controlled from a test, so tests
/// simulate collection explicitly via [simulateCollected] instead of
/// waiting on it.
class FakeObjectFinalizer<T extends Object> implements ObjectFinalizer<T> {
  FakeObjectFinalizer(this._onFinalized);

  final void Function(T token) _onFinalized;
  final Set<T> _attachedTokens = {};

  @override
  void attach(Object value, T token, {Object? detach}) {
    _attachedTokens.add(token);
  }

  @override
  void detach(Object detachToken) {
    _attachedTokens.removeWhere((token) => identical(token, detachToken));
  }

  /// Simulates the object attached with [token] having been garbage
  /// collected, invoking the real callback the finalizer was constructed
  /// with.
  void simulateCollected(T token) {
    if (!_attachedTokens.remove(token)) {
      throw StateError('$token was not attached (or was already finalized/detached)');
    }
    _onFinalized(token);
  }

  int get attachedCount => _attachedTokens.length;
}
