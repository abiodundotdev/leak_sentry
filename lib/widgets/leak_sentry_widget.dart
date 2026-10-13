import 'package:flutter/material.dart';
import 'package:leak_sentry/core/heap_dump_policy.dart';
import 'package:leak_sentry/core/internal_leak_sentry.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';
import 'package:leak_sentry/core/leak_sentry_log.dart';
import 'package:leak_sentry/core/leak_sentry_tab.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/leak_sentry_internal.dart';
import 'package:leak_sentry/models/leak_sentry_stats.dart';
import 'package:leak_sentry/models/resource_token.dart';
import 'package:leak_sentry/object_watcher/deletable_object_reporter.dart';
import 'package:leak_sentry/object_watcher/installable_watcher.dart';
import 'package:leak_sentry/object_watcher/object_watcher.dart';
import 'package:leak_sentry/ui/leak_sentry_screen.dart';

/// The entry point of LeakSentry.
///
/// Call [install] once at startup, after the bindings are initialized, or wrap
/// your app in the [LeakSentry] widget, which installs it for you, except in
/// release builds and under `flutter test`.
///
/// ```dart
/// void main() {
///   WidgetsFlutterBinding.ensureInitialized();
///   if (!kReleaseMode) LeakSentry.install();
///   runApp(const MyApp());
/// }
/// ```
///
/// Once installed, LeakSentry watches the lifecycle objects Flutter disposes
/// (`State`, `Route`, `ChangeNotifier` and `AnimationController`). An object
/// that is still reachable five seconds after its disposal is retained. When
/// enough objects are retained, or the app goes to the background, LeakSentry
/// forces a garbage collection, dumps the heap and analyzes it. Use
/// [objectWatcher] to watch anything else.
class LeakSentry extends StatefulWidget {
  const LeakSentry({super.key, required this.child});

  final Widget child;

  /// Starts watching objects and looking for leaks. Call it once; a second call
  /// throws.
  ///
  /// [retainedDelay] is how long a watched object has to become unreachable
  /// before it counts as retained. [watchers] defaults to [defaultWatchers].
  ///
  /// Throws in a release build unless [allowInRelease] is set: a heap dump
  /// freezes the app, and a release build can't be analyzed. Use
  /// [installObjectWatcher] to count retained objects there.
  static void install({
    Duration retainedDelay = HeapDumpPolicy.defaultRetainedDelay,
    List<InstallableWatcher>? watchers,
    bool allowInRelease = false,
  }) => InternalLeakSentry.instance.install(
    retainedDelay: retainedDelay,
    watchers: watchers,
    allowInRelease: allowInRelease,
  );

  /// Starts watching objects without ever dumping the heap, so
  /// [retainedObjectCount] and [objectWatcher] work, including in release
  /// builds.
  static void installObjectWatcher({
    Duration retainedDelay = HeapDumpPolicy.defaultRetainedDelay,
    List<InstallableWatcher>? watchers,
  }) => InternalLeakSentry.instance.installObjectWatcher(retainedDelay: retainedDelay, watchers: watchers);

  /// Whether [install] or [installObjectWatcher] has been called.
  static bool get isInstalled => InternalLeakSentry.instance.isInstalled;

  /// The watchers [install] uses when none are passed: `State`, `Route`,
  /// `ChangeNotifier` and `AnimationController`. Pass your own
  /// [deletableObjectReporter] to filter out objects you don't want watched.
  static List<InstallableWatcher> defaultWatchers([DeletableObjectReporter? deletableObjectReporter]) =>
      InternalLeakSentry.instance.defaultWatchers(deletableObjectReporter);

  /// Watches objects that are expected to become unreachable.
  static ObjectWatcher get objectWatcher => InternalLeakSentry.instance.objectWatcher;

  /// How many watched objects are retained right now.
  static int get retainedObjectCount => InternalLeakSentry.instance.retainedObjectCount;

  /// Watches [object], which should become unreachable soon. Shorthand for
  /// `objectWatcher.watch(object, reason)`.
  static void watch(Object object, {String? reason}) {
    final watcher = InternalLeakSentry.instance.objectWatcher;
    if (reason == null) {
      watcher.watch(object);
    } else {
      watcher.watch(object, reason);
    }
  }

  /// The configuration. Change it with `LeakSentry.config = LeakSentry.config.copyWith(...)`.
  static LeakSentryConfig get config => InternalLeakSentry.instance.config;

  static set config(LeakSentryConfig value) => InternalLeakSentry.instance.config = value;

  /// The event listeners used unless [config] replaces them.
  static List<LeakSentryEventListener> get defaultEventListeners => InternalLeakSentry.instance.defaultEventListeners;

  /// Every event LeakSentry sends, such as a heap being dumped or an analysis
  /// finishing.
  static Stream<LeakSentryEvent> get events => InternalLeakSentry.instance.events;

  /// Dumps the heap and analyzes it now, after forcing a GC. Without
  /// [forceDump], nothing is dumped if no retained object is left. The
  /// threshold, the spacing between dumps and the config's `dumpHeap` don't
  /// apply.
  ///
  /// Completes once the leaks found are in [leakHistory], so
  /// `await LeakSentry.dumpHeap(); LeakSentry.expectNoLeaks();` sees them. It
  /// stops waiting for the analysis after a minute, and does not wait for one
  /// that a custom event listener runs instead of LeakSentry's.
  static Future<void> dumpHeap({bool forceDump = false}) => InternalLeakSentry.instance.dumpHeap(forceDump: forceDump);

  /// Forces a garbage collection, as LeakSentry does before it dumps the heap,
  /// and returns whether one was confirmed. It needs no [install]. In a test it
  /// gives an object that is no longer referenced the chance to be collected,
  /// so that an unclosed resource (see [trackResource]) is reported.
  static Future<bool> runGc() => InternalLeakSentry.instance.runGc();

  /// Shows the LeakSentry screen: the leaks found so far, the scans that found
  /// them, and the switches.
  ///
  /// With a [context] it is shown on that context's navigator. Without one it is
  /// shown on the navigator below a mounted `LeakSentryOverlay`, which is what the
  /// badge uses. It does nothing if there is neither, or if the screen is already
  /// showing. [tab] is the tab it opens on.
  static Future<void> showScreen([BuildContext? context, LeakSentryTab tab = LeakSentryTab.leaks]) {
    if (context != null) return showLeakSentryScreen(context, tab: tab);
    final opener = InternalLeakSentry.instance.screenOpener;
    if (opener == null) {
      LeakSentryLog.d(
        () => 'LeakSentry.showScreen needs a context, or a LeakSentryOverlay in the widget tree to find a navigator with.',
      );
      return Future<void>.value();
    }
    return opener(tab);
  }

  /// Stream of detected leaks, deduped/grouped by [LeakReport.signature].
  static Stream<LeakReport> get leaks => InternalLeakSentry.instance.hub.leaks;

  /// Every distinct leak detected so far this session.
  static List<LeakReport> get leakHistory => InternalLeakSentry.instance.hub.leakHistory;

  /// What leak detection has cost the app so far — see [LeakSentryStats].
  static LeakSentryStats get stats => InternalLeakSentry.instance.stats;

  /// Tracks [resource] for "garbage collected without being closed"
  /// detection — for resources with no disposal-event system of their own,
  /// e.g. a raw `StreamController`. It needs no [install], and works in
  /// release builds and on web.
  static ResourceToken trackResource(Object resource, {String? label}) =>
      InternalLeakSentry.instance.resourceTracker.trackResource(resource, label: label);

  /// Throws if any leak has been detected so far this session.
  static void expectNoLeaks() => InternalLeakSentry.instance.hub.expectNoLeaks();

  /// Replaces the shared instance with a fresh one, undoing [install], so tests
  /// don't leak state into one another.
  @visibleForTesting
  static void resetForTesting() {
    InternalLeakSentry.instance.dispose();
    InternalLeakSentry.instance = InternalLeakSentry();
  }

  @override
  State<LeakSentry> createState() => _LeakSentryState();
}

class _LeakSentryState extends State<LeakSentry> implements LeakSentryInternal {
  @override
  void initState() {
    super.initState();
    // Mounting the widget more than once, or after an explicit install, is
    // fine. In a release build or under `flutter test` there is nothing to
    // install.
    InternalLeakSentry.instance.installIfNeeded();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
