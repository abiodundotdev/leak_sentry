/// Automatic memory-leak detection for Flutter.
///
/// Call `LeakSentry.install()` at startup, or wrap your app root in the
/// [LeakSentry] widget. Lifecycle objects Flutter disposes (`State`, `Route`,
/// `ChangeNotifier`, `AnimationController`) are watched, and when they are
/// retained LeakSentry forces a garbage collection, dumps the heap and
/// analyzes it. Use `LeakSentry.objectWatcher` to watch anything else, and
/// [TrackedStreamController] or `LeakSentry.trackResource` to detect resources
/// (like a `StreamController`) that are garbage collected without ever being
/// closed.
library;

export 'analysis/heap_analysis.dart' show AnalysisStep, HeapAnalysis, HeapAnalysisFailure, HeapAnalysisSuccess;
export 'analysis/leak_trace.dart' show LeakTrace, TraceNode, TraceNodeKind, TraceReference, TraceReferenceKind;
export 'analysis/node_status.dart' show NodeStatus;
export 'core/gc_trigger.dart' show GcTrigger, VmGcTrigger;
export 'core/heap_dumper.dart' show HeapDumper, RetainedObjectsDump, RetainedSetHeapDumper;
export 'core/leak_sentry_config.dart' show LeakSentryConfig;
export 'core/leak_sentry_event.dart'
    show
        DumpingHeapEvent,
        HeapAnalysisDoneEvent,
        HeapAnalysisFailedEvent,
        HeapAnalysisProgressEvent,
        HeapAnalysisSucceededEvent,
        HeapDumpEvent,
        HeapDumpFailedEvent,
        LeakSentryEvent,
        LeakSentryEventListener;
export 'core/leak_sentry_log.dart' show ConsoleLeakSentryLogger, LeakSentryLog, LeakSentryLogger;
export 'core/leak_sentry_tab.dart' show LeakSentryTab;
export 'core/log_event_listener.dart' show LogEventListener;
export 'models/creation_site.dart' show CreationSite, CreationSiteGap;
export 'models/leak_report.dart' show LeakConfidence, LeakReport, RetainingPathGap, RetainingPathInfo;
export 'models/leak_sentry_internal.dart' show LeakSentryInternal;
export 'models/leak_sentry_stats.dart' show LeakSentryStats;
export 'models/resource_token.dart' show ResourceToken;
export 'models/retaining_element.dart' show RetainingElement, RetainingElementKind;
export 'object_watcher/default_watchers.dart'
    show
        AllDisposedObjectsWatcher,
        AnimationControllerWatcher,
        ChangeNotifierWatcher,
        DisposalWatcher,
        RouteWatcher,
        StateWatcher;
export 'object_watcher/deletable_object_reporter.dart'
    show
        DefaultDelayDeletableObjectReporter,
        DelayedDeletableObjectReporter,
        DeletableObjectReporter,
        FilteringDeletableObjectReporter,
        RetainTrigger,
        TrackedObjectReachability,
        TrackedObjectReachabilityDeletion,
        TriggeredDeletableObjectReporter,
        UntrackedObjectReachability;
export 'object_watcher/delayed_executor.dart' show DelayedExecutor, SchedulerDelayedExecutor;
export 'object_watcher/installable_watcher.dart' show InstallableWatcher;
export 'object_watcher/keyed_weak_reference.dart' show KeyedWeakReference, RetainedObjectSnapshot;
export 'object_watcher/object_watcher.dart' show CheckRetainedExecutor, ObjectWatcher;
export 'object_watcher/retained_object_tracker.dart'
    show OnObjectRetainedListener, RetainedObjectTracker, WeakReferenceRetainedObjectTracker;
export 'object_watcher/scheduler.dart' show ScheduledTask, Scheduler, TimerScheduler;
export 'object_watcher/uptime_clock.dart' show UptimeClock, systemUptime;
export 'utils/tracked_stream_controller.dart' show TrackedStreamController;
export 'ui/leak_sentry_screen.dart' show LeakSentryScreen;
export 'widgets/leak_sentry_overlay.dart' show LeakSentryOverlay;
export 'widgets/leak_sentry_widget.dart' show LeakSentry;
