/// A change to the retained instances, as the heap dump trigger sees it.
sealed class RetainInstanceEvent {
  const RetainInstanceEvent();
}

/// Every retained object has been garbage collected.
final class NoMoreObjectsEvent extends RetainInstanceEvent {
  const NoMoreObjectsEvent();
}

/// Some objects are retained, but fewer than the threshold while the app is
/// visible.
final class BelowThresholdEvent extends RetainInstanceEvent {
  const BelowThresholdEvent(this.retainedCount);

  final int retainedCount;
}

/// The heap would be dumped, but something forbids it.
final class DumpingDisabledEvent extends RetainInstanceEvent {
  const DumpingDisabledEvent(this.reason);

  final String reason;
}

/// The heap would be dumped, but it was dumped less than a minute ago.
final class DumpHappenedRecentlyEvent extends RetainInstanceEvent {
  const DumpHappenedRecentlyEvent();
}

/// Called when the retained instances change.
typedef OnRetainInstanceListener = void Function(RetainInstanceEvent event);
