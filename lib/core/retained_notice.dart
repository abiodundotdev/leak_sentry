import 'package:flutter/foundation.dart';
import 'package:leak_sentry/core/retain_instance_event.dart';
import 'package:leak_sentry/core/retained_object_notifier.dart';
import 'package:leak_sentry/models/leak_sentry_internal.dart';

/// What the retained-object notice says right now.
enum RetainedNoticeKind {
  /// Objects are retained, and the heap isn't dumped yet. See [RetainedNotice.reason].
  held,

  /// Every retained object was collected.
  allClear,

  /// A heap dump was requested and nothing was retained.
  nothingOnRequest,
}

/// A notice about retained objects, as data, for the badge to show.
class RetainedNotice {
  const RetainedNotice.held({required this.objectCount, required this.text, this.reason})
    : kind = RetainedNoticeKind.held;

  const RetainedNotice.allClear() : kind = RetainedNoticeKind.allClear, objectCount = 0, text = '', reason = null;

  const RetainedNotice.nothingOnRequest()
    : kind = RetainedNoticeKind.nothingOnRequest,
      objectCount = 0,
      text = '',
      reason = null;

  final RetainedNoticeKind kind;

  /// How many objects are retained. Zero unless the notice is [RetainedNoticeKind.held].
  final int objectCount;

  /// What the heap dump trigger says. It is the log's wording, so a screen has
  /// its own and reads [reason] instead.
  final String text;

  /// Why the heap isn't dumped yet, or null when a dump just failed.
  final RetainInstanceEvent? reason;

  @override
  bool operator ==(Object other) =>
      other is RetainedNotice &&
      other.kind == kind &&
      other.objectCount == objectCount &&
      other.text == text &&
      _sameReason(other.reason, reason);

  @override
  int get hashCode => Object.hash(kind, objectCount, text);

  @override
  String toString() => 'RetainedNotice($kind, $objectCount${reason == null ? '' : ', ${reason.runtimeType}'})';

  static bool _sameReason(RetainInstanceEvent? a, RetainInstanceEvent? b) {
    if (a == null || b == null) return a == b;
    if (a.runtimeType != b.runtimeType) return false;
    return switch ((a, b)) {
      (BelowThresholdEvent(retainedCount: final x), BelowThresholdEvent(retainedCount: final y)) => x == y,
      (DumpingDisabledEvent(reason: final x), DumpingDisabledEvent(reason: final y)) => x == y,
      _ => true, // the same kind of event, which has nothing else to compare
    };
  }
}

/// Holds the notice the heap dump trigger last asked to show, for the badge to
/// listen to. It is the engine's own [RetainedObjectNotifier].
///
/// The trigger repeats "still waiting" every couple of seconds; a repeat that
/// changes nothing doesn't notify.
///
/// A heap dump that was under way when the engine was disposed can still call
/// it a moment later. It ignores that, instead of throwing as a disposed
/// notifier does.
class RetainedNoticeController extends ValueNotifier<RetainedNotice?> implements RetainedObjectNotifier, LeakSentryInternal {
  RetainedNoticeController() : super(null);

  bool _disposed = false;

  @override
  void showRetainedCount({required int objectCount, required String contentText, RetainInstanceEvent? reason}) {
    if (_disposed) return;
    value = RetainedNotice.held(objectCount: objectCount, text: contentText, reason: reason);
  }

  @override
  void showNoMoreRetainedObjects() {
    if (_disposed) return;
    value = const RetainedNotice.allClear();
  }

  @override
  void dismissRetainedCount() {
    if (_disposed) return;
    final kind = value?.kind;
    if (kind == RetainedNoticeKind.held || kind == RetainedNoticeKind.allClear) value = null;
  }

  @override
  void showNoRetainedObjectsOnRequest() {
    if (_disposed) return;
    value = const RetainedNotice.nothingOnRequest();
  }

  @override
  void dismissNoRetainedObjectsOnRequest() {
    if (_disposed) return;
    if (value?.kind == RetainedNoticeKind.nothingOnRequest) value = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
