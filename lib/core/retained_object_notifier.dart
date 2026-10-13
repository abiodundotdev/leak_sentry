import 'package:leak_sentry/core/retain_instance_event.dart';

/// What the heap dump trigger tells the developer while it waits. The trigger
/// makes these calls with the texts in `LeakSentryStrings`, and the engine's own
/// `RetainedNoticeController` turns them into what the badge shows. The default
/// [SilentRetainedObjectNotifier] shows nothing, and the log has the same facts.
abstract interface class RetainedObjectNotifier {
  /// Shows how many objects are retained, with [contentText] saying what
  /// happens next.
  ///
  /// [reason] says why the heap isn't dumped yet, as data, so that a screen
  /// need not read it out of [contentText]: [BelowThresholdEvent] while too few
  /// objects are retained, [DumpHappenedRecentlyEvent] while the last dump is
  /// too recent, [DumpingDisabledEvent] while something forbids it. It is null
  /// when the dump failed.
  void showRetainedCount({required int objectCount, required String contentText, RetainInstanceEvent? reason});

  /// Says every retained object was collected.
  void showNoMoreRetainedObjects();

  /// Removes the retained count.
  void dismissRetainedCount();

  /// Says a requested heap dump found nothing retained.
  void showNoRetainedObjectsOnRequest();

  /// Removes the notice shown by [showNoRetainedObjectsOnRequest].
  void dismissNoRetainedObjectsOnRequest();
}

/// A [RetainedObjectNotifier] that shows nothing.
class SilentRetainedObjectNotifier implements RetainedObjectNotifier {
  const SilentRetainedObjectNotifier();

  @override
  void showRetainedCount({required int objectCount, required String contentText, RetainInstanceEvent? reason}) {}

  @override
  void showNoMoreRetainedObjects() {}

  @override
  void dismissRetainedCount() {}

  @override
  void showNoRetainedObjectsOnRequest() {}

  @override
  void dismissNoRetainedObjectsOnRequest() {}
}

/// Passes every call to each of [notifiers], in order. One that throws doesn't
/// keep the others from hearing the call.
class CompositeRetainedObjectNotifier implements RetainedObjectNotifier {
  const CompositeRetainedObjectNotifier(this.notifiers);

  final List<RetainedObjectNotifier> notifiers;

  void _each(void Function(RetainedObjectNotifier notifier) call) {
    Object? firstError;
    StackTrace? firstStack;
    for (final notifier in notifiers) {
      try {
        call(notifier);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
      }
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }

  @override
  void showRetainedCount({required int objectCount, required String contentText, RetainInstanceEvent? reason}) =>
      _each((n) => n.showRetainedCount(objectCount: objectCount, contentText: contentText, reason: reason));

  @override
  void showNoMoreRetainedObjects() => _each((n) => n.showNoMoreRetainedObjects());

  @override
  void dismissRetainedCount() => _each((n) => n.dismissRetainedCount());

  @override
  void showNoRetainedObjectsOnRequest() => _each((n) => n.showNoRetainedObjectsOnRequest());

  @override
  void dismissNoRetainedObjectsOnRequest() => _each((n) => n.dismissNoRetainedObjectsOnRequest());
}
