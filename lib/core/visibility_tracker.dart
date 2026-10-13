import 'package:flutter/widgets.dart';

/// Reports whether the app is visible.
abstract interface class VisibilityTracker {
  /// Starts calling [listener] each time visibility changes.
  void start(void Function(bool visible) listener);

  void stop();
}

/// A [VisibilityTracker] driven by [AppLifecycleState].
///
/// The app is visible while `resumed` or `inactive` (a dialog, split screen or
/// app switcher on top of it) and invisible while `hidden`, `paused` or
/// `detached`.
class LifecycleVisibilityTracker with WidgetsBindingObserver implements VisibilityTracker {
  void Function(bool visible)? _listener;
  bool _lastUpdate = true;

  @override
  void start(void Function(bool visible) listener) {
    if (_listener != null) return;
    _listener = listener;
    final binding = WidgetsFlutterBinding.ensureInitialized();
    binding.addObserver(this);
    final state = binding.lifecycleState;
    // The lifecycle state is null until the platform reports one, and the app
    // is running, so assume it is visible then.
    _lastUpdate = state == null || _isVisible(state);
    if (!_lastUpdate) listener(false);
  }

  @override
  void stop() {
    if (_listener == null) return;
    WidgetsBinding.instance.removeObserver(this);
    _listener = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = _isVisible(state);
    if (visible == _lastUpdate) return;
    _lastUpdate = visible;
    _listener?.call(visible);
  }

  static bool _isVisible(AppLifecycleState state) =>
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
}
