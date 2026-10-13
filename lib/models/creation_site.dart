/// The line of application code responsible for creating a leaked object —
/// the first stack frame, when the object was created, that isn't Dart SDK,
/// Flutter, or `leak_sentry` code.
class CreationSite {
  const CreationSite({required this.uri, this.member, this.line, this.column});

  /// The enclosing function or constructor, e.g. `_PageState.initState`.
  final String? member;

  /// The source file, in whatever form the VM reported it (typically
  /// `package:my_app/page.dart`).
  final String uri;

  final int? line;
  final int? column;

  @override
  String toString() {
    final position = line == null ? uri : (column == null ? '$uri:$line' : '$uri:$line:$column');
    return member == null ? position : '$member ($position)';
  }
}

/// Why no creation site is known for a leaked object.
///
/// A leak report always has a place to start looking, or says why it hasn't:
/// see `LeakReport.creationSite`, `LeakReport.watchSite`, `LeakReport.classSite`
/// and `LeakReport.creationSiteGap`.
enum CreationSiteGap {
  /// Flutter reports the creation of objects only in debug builds, so a
  /// profile or release build has no creation stacks.
  notDebugBuild,

  /// A web build's stack traces don't map to Dart source.
  web,

  /// Flutter never reported the object being created. It was created before
  /// LeakSentry was installed, or it is a `ChangeNotifier` whose constructor
  /// doesn't call `ChangeNotifier.maybeDispatchObjectCreation`, or a `State`
  /// whose `initState` doesn't call `super.initState()`.
  notAnnounced,

  /// Every frame of the creation stack is Dart SDK, Flutter or LeakSentry code,
  /// or the object's own constructor. Flutter announces a `State` from inside
  /// `State.initState`, so a `State` that doesn't override `initState` has no
  /// application frame to show.
  onlyFrameworkFrames,

  /// The creation stack has no symbols, because the app was built with
  /// `--split-debug-info`.
  symbolless,

  /// The creation stack could not be read.
  unparseable,
}
