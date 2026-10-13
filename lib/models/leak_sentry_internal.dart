/// Marks an object that belongs to LeakSentry itself, such as the state of its
/// own screens.
///
/// The object router never reports one as created or disposed, so no watcher
/// ever watches it: LeakSentry's screens come and go while a developer looks at
/// leaks, and they must not become leaks of their own, or the count a developer
/// is looking at would change as they look.
abstract interface class LeakSentryInternal {}
