import 'package:leak_sentry/core/visibility_tracker.dart';

/// A [VisibilityTracker] a test drives with [emit].
class FakeVisibilityTracker implements VisibilityTracker {
  void Function(bool visible)? _listener;

  bool get isStarted => _listener != null;

  @override
  void start(void Function(bool visible) listener) => _listener = listener;

  @override
  void stop() => _listener = null;

  void emit(bool visible) => _listener?.call(visible);
}
