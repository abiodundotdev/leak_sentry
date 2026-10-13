import 'package:leak_sentry/core/retain_instance_event.dart';
import 'package:leak_sentry/core/retained_object_notifier.dart';

/// A [RetainedObjectNotifier] that writes down what it was asked to show.
class RecordingNotifier implements RetainedObjectNotifier {
  /// One line per call, in order, such as `retained(2, "App visible...")`.
  final List<String> calls = [];

  /// The reason given with each `showRetainedCount`, in order: null when the call gave none.
  final List<RetainInstanceEvent?> reasons = [];

  @override
  void showRetainedCount({required int objectCount, required String contentText, RetainInstanceEvent? reason}) {
    calls.add('retained($objectCount, "$contentText")');
    reasons.add(reason);
  }

  @override
  void showNoMoreRetainedObjects() => calls.add('noMoreRetained');

  @override
  void dismissRetainedCount() => calls.add('dismissRetained');

  @override
  void showNoRetainedObjectsOnRequest() => calls.add('noRetainedOnRequest');

  @override
  void dismissNoRetainedObjectsOnRequest() => calls.add('dismissNoRetainedOnRequest');
}
