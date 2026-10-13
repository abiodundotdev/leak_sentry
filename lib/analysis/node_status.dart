/// What one step of a leak's path is, as far as LeakSentry can tell.
enum NodeStatus {
  /// Something that is meant to be alive: a class, a static variable, the
  /// binding. A leak is not its fault.
  inUse,

  /// Something that should have been garbage collected by now. The leaked
  /// object is always this, and so is everything it keeps alive further down.
  shouldBeGone,

  /// LeakSentry cannot tell.
  unclear,
}
