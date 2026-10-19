import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:leak_sentry/analysis/background_heap_analyzer.dart';
import 'package:leak_sentry/analysis/heap_analyzer.dart';
import 'package:leak_sentry/core/gc_trigger.dart';
import 'package:leak_sentry/core/heap_dump_control.dart';
import 'package:leak_sentry/core/heap_dump_policy.dart';
import 'package:leak_sentry/core/heap_dump_trigger.dart';
import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/core/leak_report_hub.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';
import 'package:leak_sentry/core/leak_sentry_log.dart';
import 'package:leak_sentry/core/leak_sentry_tab.dart';
import 'package:leak_sentry/core/leak_sentry_strings.dart';
import 'package:leak_sentry/core/log_event_listener.dart';
import 'package:leak_sentry/core/resource_tracker.dart';
import 'package:leak_sentry/core/retained_notice.dart';
import 'package:leak_sentry/core/retained_object_notifier.dart';
import 'package:leak_sentry/core/visibility_tracker.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/leak_sentry_internal.dart';
import 'package:leak_sentry/models/leak_sentry_stats.dart';
import 'package:leak_sentry/models/object_finalizer.dart';
import 'package:leak_sentry/models/resource_token.dart';
import 'package:leak_sentry/models/vm_bridge.dart';
import 'package:leak_sentry/object_watcher/default_watchers.dart';
import 'package:leak_sentry/object_watcher/delayed_executor.dart';
import 'package:leak_sentry/object_watcher/deletable_object_reporter.dart';
import 'package:leak_sentry/object_watcher/installable_watcher.dart';
import 'package:leak_sentry/object_watcher/object_event_router.dart';
import 'package:leak_sentry/object_watcher/object_watcher.dart';
import 'package:leak_sentry/object_watcher/scheduler.dart';
import 'package:leak_sentry/object_watcher/uptime_clock.dart';

/// Wires the object watcher, the heap dump trigger and the analysis together.
///
/// There is one process-wide [instance]. Tests build their own, with a fake
/// clock, scheduler, GC and visibility, and [dispose] it afterwards.
class InternalLeakSentry {
  InternalLeakSentry({
    UptimeClock? clock,
    Scheduler? scheduler,
    VmBridge vm = const RealVmBridge(),
    GcTrigger? gcTrigger,
    ObjectEventRouter? router,
    VisibilityTracker? visibilityTracker,
    RetainedObjectNotifier notifier = const SilentRetainedObjectNotifier(),
    DateTime Function()? wallClock,
    LeakCatalog? catalog,
    String? Function()? testEnvironment,
    bool? isReleaseBuild,
    bool? isWeb,
    Duration listenerWait = HeapDumpPolicy.maxListenerWait,
    Duration analysisWait = HeapDumpPolicy.maxAnalysisWait,
    ObjectFinalizer<ResourceToken> Function(void Function(ResourceToken token))? resourceFinalizerFactory,
  }) : _clock = clock ?? systemUptime,
       _scheduler = scheduler ?? const TimerScheduler(),
       _vm = vm,
       router = router ?? ObjectEventRouter.shared,
       _visibilityTracker = visibilityTracker ?? LifecycleVisibilityTracker(),
       _extraNotifier = notifier,
       catalog = catalog ?? LeakCatalog(now: wallClock),
       _testEnvironment = testEnvironment ?? _flutterTestEnvironment,
       _isReleaseBuild = isReleaseBuild ?? kReleaseMode,
       _isWeb = isWeb ?? kIsWeb,
       _listenerWait = listenerWait,
       _analysisWait = analysisWait {
    _gcTrigger = gcTrigger ?? VmGcTrigger(vm: _vm, isWeb: _isWeb);
    _delayedExecutor = SchedulerDelayedExecutor(scheduler: _scheduler, clock: _clock);
    objectWatcher = ObjectWatcher(
      clock: _clock,
      checkRetainedExecutor: (task) => _delayedExecutor.executeWithDelay(retainedDelay, task),
      isEnabled: _isEnabled,
      creationStackOf: this.router.creationSites.take,
    );
    resourceTracker = ResourceTracker(onLeak: _onResourceLeak, finalizerFactory: resourceFinalizerFactory, isWeb: _isWeb);
  }

  /// The process-wide instance the `LeakSentry` API uses.
  static InternalLeakSentry instance = InternalLeakSentry();

  final UptimeClock _clock;
  final Scheduler _scheduler;
  final VmBridge _vm;
  final VisibilityTracker _visibilityTracker;
  final RetainedObjectNotifier _extraNotifier;
  final String? Function() _testEnvironment;
  final bool _isReleaseBuild;
  final bool _isWeb;
  final Duration _listenerWait;
  final Duration _analysisWait;
  late final GcTrigger _gcTrigger;
  late final SchedulerDelayedExecutor _delayedExecutor;

  /// The router default watchers listen through.
  final ObjectEventRouter router;

  /// The object watcher.
  late final ObjectWatcher objectWatcher;

  /// Detects resources garbage collected without being closed.
  late final ResourceTracker resourceTracker;

  /// The leaks found so far, each reported once, as the `LeakSentry` API shows
  /// them.
  final LeakReportHub hub = LeakReportHub();

  /// The leaks found so far as the screens show them: grouped as distinct leaks,
  /// counted over every scan, with the scans themselves.
  final LeakCatalog catalog;

  /// What the badge says while objects are retained. The heap dump trigger
  /// reports to it, next to the notifier the engine was given.
  final RetainedNoticeController notices = RetainedNoticeController();

  late final RetainedObjectNotifier _notifier = CompositeRetainedObjectNotifier([notices, _extraNotifier]);

  /// Whether a LeakSentry screen is on show. The badge hides while one is.
  final ValueNotifier<bool> screenOpen = _ScreenOpenFlag();
  int _openScreens = 0;

  /// Whether a LeakSentry screen is on show right now: no waiting for the flag.
  bool get isScreenOpen => _openScreens > 0;

  /// Opens the LeakSentry screen on a tab. The badge sets it while it is on the
  /// screen, because only it knows which navigator the screen goes on.
  Future<void> Function(LeakSentryTab tab)? screenOpener;

  /// A LeakSentry screen came on show. Every one that does must say so, and say
  /// when it goes ([screenClosed]).
  void screenOpened() {
    _openScreens++;
    _syncScreenOpen();
  }

  void screenClosed() {
    if (_openScreens > 0) _openScreens--;
    _syncScreenOpen();
  }

  // The flag changes after the call that caused it, never in the middle of it:
  // a screen goes away while the framework is tearing a widget tree down, and
  // what listens to the flag rebuilds.
  void _syncScreenOpen() {
    scheduleMicrotask(() {
      if (_disposed) return;
      final open = _openScreens > 0;
      if (screenOpen.value != open) screenOpen.value = open;
    });
  }

  final StreamController<LeakSentryEvent> _eventsController = StreamController<LeakSentryEvent>.broadcast();

  LeakSentryConfig _config = const LeakSentryConfig();
  Duration? _retainedDelay;
  StackTrace? _installStack;
  HeapDumpControl? _heapDumpControl;
  HeapDumpTrigger? _heapDumpTrigger;
  List<InstallableWatcher> _installedWatchers = const [];
  bool _dumpEnabledInAboutScreen = true;
  bool _disposed = false;

  // The analyses that finished, most recent last, and the callers waiting for
  // one, both by the id of the dump they are of.
  static const int _maxRememberedAnalyses = 32;
  final Set<String> _finishedAnalyses = {};
  final Map<String, Completer<void>> _analysisWaiters = {};

  late final HeapDumper _defaultHeapDumper = RetainedSetHeapDumper(
    tracker: objectWatcher.tracker,
    vm: _vm,
    uptime: _clock,
  );

  /// The event listeners used unless the config replaces them.
  late final List<LeakSentryEventListener> defaultEventListeners = List.unmodifiable([
    const LogEventListener(),
    BackgroundHeapAnalyzer(
      analyzer: RetainedSetHeapAnalyzer(vm: _vm, config: () => config, stats: stats),
      hub: hub,
      sendEvent: sendEvent,
    ),
  ]);

  /// What detection has cost so far.
  LeakSentryStats get stats => router.stats;

  /// Every event, in the order it was sent, whichever listeners the config has.
  Stream<LeakSentryEvent> get events => _eventsController.stream;

  /// Whether [install] or [installObjectWatcher] has been called.
  bool get isInstalled => _installStack != null;

  /// Whether this is a release build, in which nothing is installed unless the app asked for it.
  bool get isReleaseBuild => _isReleaseBuild;

  /// How long a watched object has to become unreachable before it counts as
  /// retained.
  Duration get retainedDelay => _retainedDelay ?? HeapDumpPolicy.defaultRetainedDelay;

  LeakSentryConfig get config => _config;

  set config(LeakSentryConfig value) {
    _config = value;
    // A changed config may allow dumping again, which schedules the check that
    // looks at objects that piled up meanwhile.
    _heapDumpControl?.iCanHasHeap();
  }

  /// The "Scan automatically" switch of the Settings tab (the name predates the
  /// tab). While it is off, the heap is dumped only when the developer asks for it.
  bool get dumpEnabledInAboutScreen => _dumpEnabledInAboutScreen;

  set dumpEnabledInAboutScreen(bool value) {
    _dumpEnabledInAboutScreen = value;
    _heapDumpControl?.iCanHasHeap();
  }

  /// How many watched objects are retained right now.
  int get retainedObjectCount => objectWatcher.retainedObjectCount;

  /// Whether the heap may be dumped now, and if not, what stops it. Asking
  /// has no effect.
  ICanHazHeap get heapDumpPermission =>
      _heapDumpControl?.peek() ?? const SilentNope(_notInstalledReason, HeapDumpBlock.notInstalled);

  static String _notInstalledReason() => LeakSentryStrings.notInstalled;

  /// Whether the VM service, which the retaining paths come from, can be reached.
  Future<bool> vmServiceReachable() => _vm.isReachable();

  /// What the screens use to do something later, such as refreshing "5 min ago".
  /// Tests give the engine a scheduler that only moves when they say so.
  Scheduler get scheduler => _scheduler;

  /// Starts watching objects and looking for leaks.
  ///
  /// Refuses to run in a release build unless [allowInRelease] is set, because
  /// a heap dump freezes the app and a release build has no VM service to
  /// analyze it with. Use [installObjectWatcher] to count retained objects
  /// there.
  void install({
    Duration retainedDelay = HeapDumpPolicy.defaultRetainedDelay,
    List<InstallableWatcher>? watchers,
    bool allowInRelease = false,
  }) {
    _checkCanInstall(retainedDelay);
    if (_isReleaseBuild && !allowInRelease) throw StateError(_releaseBuildMessage);
    // The web has no way to force a GC or to find a retaining path, so what
    // would be reported there could not be trusted: it only counts.
    _install(retainedDelay: retainedDelay, watchers: watchers, loadLeakSentry: !_isWeb);
  }

  /// Installs with the defaults, unless already installed, in a release build,
  /// or in a test environment. Returns whether it installed.
  ///
  /// This is what mounting the `LeakSentry` widget does. A test environment is
  /// skipped because the watchers schedule timers, and a widget test fails
  /// when a timer is still pending at its end, which would break the tests of
  /// every app that wraps its root in the widget.
  bool installIfNeeded() {
    if (isInstalled || _isReleaseBuild || _testEnvironment() != null) return false;
    install();
    return true;
  }

  /// Starts watching objects, without the heap dump trigger and the analysis.
  /// It is safe in release builds: it only counts retained objects.
  void installObjectWatcher({
    Duration retainedDelay = HeapDumpPolicy.defaultRetainedDelay,
    List<InstallableWatcher>? watchers,
  }) {
    _checkCanInstall(retainedDelay);
    _install(retainedDelay: retainedDelay, watchers: watchers, loadLeakSentry: false);
  }

  /// The watchers [install] uses when none are passed.
  List<InstallableWatcher> defaultWatchers([DeletableObjectReporter? deletableObjectReporter]) {
    final reporter = deletableObjectReporter ?? objectWatcher;
    return [
      StateWatcher(reporter, router: router),
      RouteWatcher(reporter, router: router),
      ChangeNotifierWatcher(reporter, router: router),
      AnimationControllerWatcher(reporter, router: router),
    ];
  }

  /// Dumps the heap and analyzes it. Without [forceDump], nothing happens if no
  /// retained object is left after a GC.
  ///
  /// Completes once the leaks of that dump are in the hub (or, if the analysis
  /// takes too long, after [HeapDumpPolicy.maxAnalysisWait]), so that
  /// `await dumpHeap(); expectNoLeaks()` sees them.
  Future<void> dumpHeap({bool forceDump = false}) async {
    final trigger = _heapDumpTrigger;
    if (trigger == null) return;
    final dumpId = await trigger.onDumpHeapReceived(forceDump: forceDump);
    if (dumpId == null || !_analyzesDumps) return;
    await _waitForAnalysis(dumpId);
  }

  /// Whether the listeners include LeakSentry's own analysis, which is the only
  /// one that can be waited for.
  bool get _analyzesDumps =>
      (_config.eventListeners ?? defaultEventListeners).any((listener) => listener is BackgroundHeapAnalyzer);

  Future<void> _waitForAnalysis(String dumpId) {
    if (_finishedAnalyses.contains(dumpId)) return Future<void>.value();
    final waiter = _analysisWaiters.putIfAbsent(dumpId, Completer<void>.new);
    return waiter.future.timeout(_analysisWait, onTimeout: () => _analysisWaiters.remove(dumpId));
  }

  void _analysisFinished(String dumpId) {
    _finishedAnalyses.add(dumpId);
    if (_finishedAnalyses.length > _maxRememberedAnalyses) _finishedAnalyses.remove(_finishedAnalyses.first);
    _analysisWaiters.remove(dumpId)?.complete();
  }

  /// Forces a garbage collection, the way the heap dump trigger does, and
  /// returns whether one was confirmed. It needs no [install]. Useful in tests,
  /// to give an unclosed resource the chance to be collected and reported.
  Future<bool> runGc() => _gcTrigger.runGc();

  /// Sends [event] to the listeners, one after the other. A listener that
  /// throws is logged and skipped, so one broken listener doesn't cut off the
  /// others or abort a heap dump, and one that takes longer than
  /// [HeapDumpPolicy.maxListenerWait] is no longer waited for.
  ///
  /// The listeners of one chain of events hear them in order. The analysis
  /// starts when the heap dump event is sent and runs while the listeners after
  /// the analyzer are still hearing it, so a late listener can hear the
  /// analysis events first.
  Future<void> sendEvent(LeakSentryEvent event) async {
    if (!_eventsController.isClosed) _eventsController.add(event);
    // Before any listener, and not as one: the config can replace the
    // listeners, and the screens must hear every event whichever are in use.
    if (!_disposed) {
      try {
        catalog.onEvent(event);
      } catch (error, stackTrace) {
        LeakSentryLog.d(() => 'The leak catalog failed on ${event.runtimeType}', error: error, stackTrace: stackTrace);
      }
    }
    for (final listener in List.of(_config.eventListeners ?? defaultEventListeners)) {
      try {
        await Future<void>.sync(() => listener.onEvent(event)).timeout(_listenerWait);
      } on TimeoutException {
        LeakSentryLog.d(
          () =>
              'An event listener took more than ${_listenerWait.inMilliseconds} ms on ${event.runtimeType}, '
              'not waiting for it any longer',
        );
      } catch (error, stackTrace) {
        LeakSentryLog.d(() => 'An event listener failed on ${event.runtimeType}', error: error, stackTrace: stackTrace);
      }
    }
    if (event is HeapAnalysisDoneEvent) _analysisFinished(event.uniqueId);
  }

  /// Forgets every leak found so far, in the hub and in the catalog the screens
  /// show.
  void clearLeaks() {
    hub.clear();
    catalog.clear();
  }

  void _onResourceLeak(LeakReport report) {
    hub.add(report);
    try {
      catalog.addResourceLeak(report);
    } catch (error, stackTrace) {
      LeakSentryLog.d(() => 'The leak catalog failed on a resource leak', error: error, stackTrace: stackTrace);
    }
  }

  /// Undoes [install], forgets everything watched and every leak found, and
  /// makes this instance unusable. For tests.
  void dispose() {
    _uninstall();
    hub.clear();
    _disposed = true;
    catalog.dispose();
    notices.dispose();
    screenOpen.dispose();
    screenOpener = null;
    for (final waiter in _analysisWaiters.values) {
      waiter.complete();
    }
    _analysisWaiters.clear();
  }

  void _uninstall() {
    for (final watcher in _installedWatchers) {
      try {
        watcher.uninstall();
      } catch (error, stackTrace) {
        LeakSentryLog.d(() => 'A watcher failed to uninstall', error: error, stackTrace: stackTrace);
      }
    }
    _installedWatchers = const [];
    _visibilityTracker.stop();
    _heapDumpTrigger?.dispose();
    _heapDumpTrigger = null;
    _heapDumpControl = null;
    objectWatcher.removeOnObjectRetainedListener(_scheduleRetainedObjectCheck);
    _delayedExecutor.cancelAll();
    objectWatcher.clearWatchedObjects();
    _installStack = null;
    _retainedDelay = null;
  }

  void _checkCanInstall(Duration retainedDelay) {
    if (_disposed) throw StateError('This LeakSentry instance was disposed');
    final installStack = _installStack;
    if (installStack != null) {
      throw StateError('LeakSentry already installed. It was first installed here:\n$installStack');
    }
    if (retainedDelay.isNegative) {
      throw ArgumentError.value(retainedDelay, 'retainedDelay', 'must be at least 0 ms');
    }
  }

  void _install({
    required Duration retainedDelay,
    required List<InstallableWatcher>? watchers,
    required bool loadLeakSentry,
  }) {
    _retainedDelay = retainedDelay;
    // Unless the app set a logger, logging goes to the console in debug and
    // profile builds only.
    if (!_isReleaseBuild) LeakSentryLog.logger ??= const ConsoleLeakSentryLogger();
    if (_isWeb) {
      LeakSentryLog.d(
        () =>
            'LeakSentry cannot force a garbage collection or look up retaining paths on the web, so it only counts '
            'retained objects: see LeakSentry.retainedObjectCount.',
      );
    }
    if (!kDebugMode) {
      LeakSentryLog.d(
        () =>
            'Flutter only reports object creation and disposal in debug builds, so States, Routes and '
            'ChangeNotifiers are not watched automatically in this one. Watch objects yourself with '
            'LeakSentry.objectWatcher.',
      );
    }
    final toInstall = watchers ?? defaultWatchers();
    try {
      if (loadLeakSentry) _loadLeakSentry();
      for (final watcher in toInstall) {
        watcher.install();
        _installedWatchers = [..._installedWatchers, watcher];
      }
    } catch (_) {
      // Leave nothing half installed, so the call can be retried.
      _uninstall();
      rethrow;
    }
    // Only now that initialization is done.
    _installStack = StackTrace.current;
  }

  void _loadLeakSentry() {
    objectWatcher.addOnObjectRetainedListener(_scheduleRetainedObjectCheck);
    final control = HeapDumpControl(
      isInstalled: () => isInstalled,
      config: () => _config,
      dumpEnabledInAboutScreen: () => _dumpEnabledInAboutScreen,
      testEnvironment: _testEnvironment,
      scheduleRetainedObjectCheck: _scheduleRetainedObjectCheck,
    );
    _heapDumpControl = control;
    final trigger = HeapDumpTrigger(
      retainedObjectTracker: objectWatcher.tracker,
      gcTrigger: _gcTrigger,
      configProvider: () => _config,
      heapDumperProvider: () => _config.heapDumper ?? _defaultHeapDumper,
      heapDumpControl: control,
      clock: _clock,
      scheduler: _scheduler,
      retainedDelayProvider: () => retainedDelay,
      sendEvent: sendEvent,
      onRetainInstanceListener: (_) {},
      notifier: _notifier,
      stats: stats,
    );
    
    _heapDumpTrigger = trigger;
    _visibilityTracker.start(trigger.onApplicationVisibilityChanged);

    // Scheduled so the log comes after the app had the chance to update the
    // config.
    _scheduler.postDelayed(Duration.zero, () {
      if (_heapDumpControl != control) return;
      LeakSentryLog.d(() {
        final iCanHasHeap = control.iCanHasHeap();
        return switch (iCanHasHeap) {
          Yup() => LeakSentryStrings.heapDumpEnabled,
          Nope(:final reason) => LeakSentryStrings.heapDumpDisabled(reason()),
        };
      });
    });
  }

  bool _isEnabled() {
    if (isInstalled) return true;
    LeakSentryLog.d(() => 'Ignoring a watched object: LeakSentry is not installed');
    return false;
  }

  void _scheduleRetainedObjectCheck() => _heapDumpTrigger?.scheduleRetainedObjectCheck();

  static String? _flutterTestEnvironment() {
    if (kIsWeb) return null;
    return Platform.environment.containsKey('FLUTTER_TEST') ? 'FLUTTER_TEST' : null;
  }

  static const String _releaseBuildMessage = '''
LeakSentry in a release build

LeakSentry should only be used in debug and profile builds, but this is a release build.
Install it only outside of release builds:

  if (!kReleaseMode) LeakSentry.install();

If you are sure you want LeakSentry in a release build, pass allowInRelease: true to
LeakSentry.install(). To only count retained objects in a release build, without ever
dumping the heap, call LeakSentry.installObjectWatcher() instead.''';
}

/// The flag of [InternalLeakSentry.screenOpen]. It belongs to LeakSentry, so it is
/// never watched, and it can be disposed more than once.
class _ScreenOpenFlag extends ValueNotifier<bool> implements LeakSentryInternal {
  _ScreenOpenFlag() : super(false);

  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
