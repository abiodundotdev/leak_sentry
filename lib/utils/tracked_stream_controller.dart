import 'dart:async';

import 'package:leak_sentry/core/internal_leak_sentry.dart';
import 'package:leak_sentry/models/resource_token.dart';

/// A drop-in-ish [StreamController] replacement that reports a leak if it's
/// garbage collected without ever being [close]d.
///
/// Swap `StreamController<T>()` for `TrackedStreamController<T>()` to get
/// automatic detection of the classic "forgot to close the controller in
/// dispose()" bug, with zero other code changes to how the controller is
/// used. The leak is found when the controller is garbage collected, so no VM
/// service is needed and it works in release mode and on web.
class TrackedStreamController<T> {
  TrackedStreamController({
    void Function()? onListen,
    void Function()? onPause,
    void Function()? onResume,
    FutureOr<void> Function()? onCancel,
    bool sync = false,
    String? label,
  }) : _controller = StreamController<T>(
         onListen: onListen,
         onPause: onPause,
         onResume: onResume,
         onCancel: onCancel,
         sync: sync,
       ) {
    _token = InternalLeakSentry.instance.resourceTracker.trackResource(this, label: label ?? 'StreamController<$T>');
  }

  TrackedStreamController.broadcast({void Function()? onListen, void Function()? onCancel, bool sync = false, String? label})
    : _controller = StreamController<T>.broadcast(onListen: onListen, onCancel: onCancel, sync: sync) {
    _token = InternalLeakSentry.instance.resourceTracker.trackResource(
      this,
      label: label ?? 'StreamController<$T>.broadcast',
    );
  }

  final StreamController<T> _controller;
  late final ResourceToken _token;

  Stream<T> get stream => _controller.stream;
  StreamSink<T> get sink => _controller.sink;
  bool get isClosed => _controller.isClosed;
  bool get isPaused => _controller.isPaused;
  bool get hasListener => _controller.hasListener;
  Future<void> get done => _controller.done;

  void add(T event) => _controller.add(event);
  void addError(Object error, [StackTrace? stackTrace]) => _controller.addError(error, stackTrace);
  Future<void> addStream(Stream<T> source, {bool? cancelOnError}) =>
      _controller.addStream(source, cancelOnError: cancelOnError);

  Future<void> close() {
    _token.markClosed();
    return _controller.close();
  }
}
