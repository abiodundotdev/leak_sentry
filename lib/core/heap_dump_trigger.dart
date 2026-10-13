import 'dart:async';

import 'package:leak_sentry/core/gc_trigger.dart';
import 'package:leak_sentry/core/heap_dump_control.dart';
import 'package:leak_sentry/core/heap_dump_policy.dart';
import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';
import 'package:leak_sentry/core/leak_sentry_log.dart';
import 'package:leak_sentry/core/leak_sentry_strings.dart';
import 'package:leak_sentry/core/retain_instance_event.dart';
import 'package:leak_sentry/core/retained_object_notifier.dart';
import 'package:leak_sentry/models/leak_sentry_stats.dart';
import 'package:leak_sentry/object_watcher/retained_object_tracker.dart';
import 'package:leak_sentry/object_watcher/scheduler.dart';
import 'package:leak_sentry/object_watcher/uptime_clock.dart';

/// Decides when to force a GC and when to dump the heap.
///
/// An object being retained schedules a check, and only one check is ever
/// pending. A check runs a GC if anything is retained, counts again, and then
/// waits, dumps, or retries depending on the count, whether the app is visible,
/// and how long ago the last dump was.
///
/// It runs on the main isolate, so the steps that wait (the GC, the dump, the
/// event listeners) are asynchronous and the checks are queued to run one after
/// the other.
class HeapDumpTrigger {
  HeapDumpTrigger({
    required RetainedObjectTracker retainedObjectTracker,
    required GcTrigger gcTrigger,
    required LeakSentryConfig Function() configProvider,
    required HeapDumper Function() heapDumperProvider,
    required HeapDumpControl heapDumpControl,
    required UptimeClock clock,
    required Scheduler scheduler,
    required Duration Function() retainedDelayProvider,
    required Future<void> Function(LeakSentryEvent event) sendEvent,
    required OnRetainInstanceListener onRetainInstanceListener,
    required RetainedObjectNotifier notifier,
    required LeakSentryStats stats,
    String Function()? uniqueIdFactory,
    Duration maxGcWait = HeapDumpPolicy.maxGcWait,
    Duration maxDumpWait = HeapDumpPolicy.maxDumpWait,
  }) : _tracker = retainedObjectTracker,
       _gcTrigger = gcTrigger,
       _configProvider = configProvider,
       _heapDumperProvider = heapDumperProvider,
       _heapDumpControl = heapDumpControl,
       _clock = clock,
       _scheduler = scheduler,
       _retainedDelayProvider = retainedDelayProvider,
       _sendEvent = sendEvent,
       _onRetainInstanceListener = onRetainInstanceListener,
       _notifier = notifier,
       _stats = stats,
       _newUniqueId = uniqueIdFactory ?? _defaultUniqueId(),
       _maxGcWait = maxGcWait,
       _maxDumpWait = maxDumpWait;

  final RetainedObjectTracker _tracker;
  final GcTrigger _gcTrigger;
  final LeakSentryConfig Function() _configProvider;
  final HeapDumper Function() _heapDumperProvider;
  final HeapDumpControl _heapDumpControl;
  final UptimeClock _clock;
  final Scheduler _scheduler;
  final Duration Function() _retainedDelayProvider;
  final Future<void> Function(LeakSentryEvent event) _sendEvent;
  final OnRetainInstanceListener _onRetainInstanceListener;
  final RetainedObjectNotifier _notifier;
  final LeakSentryStats _stats;
  final String Function() _newUniqueId;

  // How long a GC and a dump may take. Without a limit, one that never answers
  // would hold up every check queued after it.
  final Duration _maxGcWait;
  final Duration _maxDumpWait;

  final _SerialQueue _queue = _SerialQueue();

  bool _disposed = false;

  /// Whether a check is waiting to run. Only one can be.
  bool _checkScheduled = false;
  ScheduledTask? _pendingCheck;

  int _lastDisplayedRetainedObjectCount = 0;

  /// When the heap was last dumped. Null before the first dump, because a
  /// process-relative clock starts near zero, so a default of zero would look
  /// like a dump a moment ago.
  Duration? _lastHeapDumpUptime;

  /// When the last forced GC started.
  Duration? _lastGcStartedUptime;

  /// When the app became invisible, or null while it is visible.
  Duration? _applicationInvisibleAt;

  String? _currentEventUniqueId;

  ScheduledTask? _dismissRetainedCountTask;
  ScheduledTask? _dismissNoRetainedOnRequestTask;

  static String Function() _defaultUniqueId() {
    var counter = 0;
    return () => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${(counter++).toRadixString(36)}';
  }

  Duration get _retainedDelay => _retainedDelayProvider();

  bool get _applicationVisible => _applicationInvisibleAt == null;

  /// When the app becomes invisible the heap isn't dumped at once. The app may
  /// come back, and leaks typically appear on back press (a route popped), so
  /// the objects destroyed meanwhile get time to be watched and counted.
  bool get _applicationInvisibleLessThanWatchPeriod {
    final invisibleAt = _applicationInvisibleAt;
    return invisibleAt != null && _clock() - invisibleAt < _retainedDelay;
  }

  /// Stops everything: no further check runs.
  void dispose() {
    _disposed = true;
    _pendingCheck?.cancel();
    _pendingCheck = null;
    _checkScheduled = false;
    _dismissRetainedCountTask?.cancel();
    _dismissRetainedCountTask = null;
    _dismissNoRetainedOnRequestTask?.cancel();
    _dismissNoRetainedOnRequestTask = null;
  }

  void onApplicationVisibilityChanged(bool applicationVisible) {
    if (applicationVisible) {
      _applicationInvisibleAt = null;
    } else {
      _applicationInvisibleAt = _clock();
      // Scheduled for after the retained delay so that any route popped just
      // now has time to be watched and be part of this check.
      scheduleRetainedObjectCheck(delay: _retainedDelay);
    }
  }

  /// Schedules a check, unless one is already waiting.
  void scheduleRetainedObjectCheck({Duration delay = Duration.zero}) {
    if (_disposed || _checkScheduled) return;
    _checkScheduled = true;
    _pendingCheck = _scheduler.postDelayed(delay, () {
      _pendingCheck = null;
      unawaited(_queue.run(_runScheduledCheck));
    });
  }

  /// Dumps the heap because the developer asked to, after a GC. Without
  /// [forceDump], nothing is dumped if no retained object is left. Neither the
  /// threshold, the spacing between dumps nor [HeapDumpControl] applies.
  ///
  /// Returns the id the `HeapDumpEvent` was sent with, or null if no heap was
  /// dumped.
  Future<String?> onDumpHeapReceived({required bool forceDump}) => _queue.run<String?>(() async {
    if (_disposed) return null;
    _dismissNoRetainedOnRequestNotification();
    await _runGc();
    if (_disposed) return null;
    final retainedReferenceCount = _tracker.retainedObjectCount;
    if (!forceDump && retainedReferenceCount == 0) {
      LeakSentryLog.d(() => 'Ignoring user request to dump heap: no retained objects remaining after GC');
      _notifier.showNoRetainedObjectsOnRequest();
      _dismissNoRetainedOnRequestTask = _scheduler.postDelayed(
        HeapDumpPolicy.dismissNoRetainedObjectNotice,
        _dismissNoRetainedOnRequestNotification,
      );
      _lastDisplayedRetainedObjectCount = 0;
      return null;
    }

    LeakSentryLog.d(() => 'Dumping the heap because user requested it');
    // What the count counted is about to be dumped, so the count says nothing any more. Its notice
    // is dismissed here, because nothing else would.
    _dismissRetainedCountNotification();
    return _dumpHeap(retainedReferenceCount: retainedReferenceCount, retry: false, reason: 'user request');
  });

  Future<void> _runScheduledCheck() async {
    _checkScheduled = false;
    if (_disposed) return;
    final stopwatch = Stopwatch()..start();
    try {
      await _checkRetainedObjects();
    } catch (error, stackTrace) {
      LeakSentryLog.d(() => 'Checking retained objects failed, will retry', error: error, stackTrace: stackTrace);
      scheduleRetainedObjectCheck(delay: HeapDumpPolicy.waitAfterDumpFailed);
    } finally {
      _stats.retainedChecks++;
      _stats.retainedCheckMicros += stopwatch.elapsedMicroseconds;
    }
  }

  Future<void> _checkRetainedObjects() async {
    final iCanHasHeap = _heapDumpControl.iCanHasHeap();

    final config = _configProvider();

    if (iCanHasHeap is Nope) {
      if (iCanHasHeap is NotifyingNope) {
        // Before saying the heap can't be dumped, check that something is still
        // retained.
        final retainedReferenceCount = await _retainedCountAfterGc(config.retainedVisibleThreshold);
        if (_disposed) return;

        final nopeReason = iCanHasHeap.reason();
        final wouldDump = !_checkRetainedCount(retainedReferenceCount, config.retainedVisibleThreshold, nopeReason);

        if (wouldDump) {
          final uppercaseReason = nopeReason[0].toUpperCase() + nopeReason.substring(1);
          final disabled = DumpingDisabledEvent(uppercaseReason);
          _onRetainInstanceListener(disabled);
          _showRetainedCountNotification(
            objectCount: retainedReferenceCount,
            contentText: uppercaseReason,
            reason: disabled,
          );
        }
      } else {
        LeakSentryLog.d(() => LeakSentryStrings.heapDumpDisabled(iCanHasHeap.reason()));
      }
      return;
    }

    final retainedReferenceCount = await _retainedCountAfterGc(config.retainedVisibleThreshold);
    if (_disposed) return;

    if (_checkRetainedCount(retainedReferenceCount, config.retainedVisibleThreshold)) return;

    final lastHeapDumpUptime = _lastHeapDumpUptime;
    if (lastHeapDumpUptime != null) {
      final elapsedSinceLastDump = _clock() - lastHeapDumpUptime;
      if (elapsedSinceLastDump < HeapDumpPolicy.waitBetweenHeapDumps) {
        _onRetainInstanceListener(const DumpHappenedRecentlyEvent());
        _showRetainedCountNotification(
          objectCount: retainedReferenceCount,
          contentText: LeakSentryStrings.retainedDumpWait,
          reason: const DumpHappenedRecentlyEvent(),
        );
        scheduleRetainedObjectCheck(delay: HeapDumpPolicy.waitBetweenHeapDumps - elapsedSinceLastDump);
        return;
      }
    }

    _dismissRetainedCountNotification();
    final visibility = _applicationVisible ? 'visible' : 'not visible';
    await _dumpHeap(
      retainedReferenceCount: retainedReferenceCount,
      retry: true,
      reason: '$retainedReferenceCount retained objects, app is $visibility',
    );
  }

  /// Dumps the heap. Returns the id the `HeapDumpEvent` was sent with, or null
  /// if the dump failed or the trigger was disposed meanwhile.
  Future<String?> _dumpHeap({required int retainedReferenceCount, required bool retry, required String reason}) async {
    _currentEventUniqueId ??= _newUniqueId();
    try {
      await _sendEvent(DumpingHeapEvent(_currentEventUniqueId!));
      if (_disposed) return null;
      final heapDumpUptime = _clock();
      final stopwatch = Stopwatch()..start();
      final dump = await _heapDumperProvider().dumpHeap().timeout(_maxDumpWait);
      if (_disposed) return null;
      final duration = stopwatch.elapsed;
      _lastDisplayedRetainedObjectCount = 0;
      _lastHeapDumpUptime = _clock();
      // Whatever was watched before the dump started is in it, so it must never
      // be reported again by a later one. An object watched while a slow dump
      // was running is not in it, and is kept.
      _tracker.clearObjectsTrackedBefore(heapDumpUptime);
      _stats.heapDumps++;
      final dumpEventId = _currentEventUniqueId = _newUniqueId();
      await _sendEvent(HeapDumpEvent(dumpEventId, dump: dump, duration: duration, reason: reason));
      return dumpEventId;
    } catch (error, stackTrace) {
      _stats.heapDumpFailures++;
      await _sendEvent(
        HeapDumpFailedEvent(_currentEventUniqueId!, exception: error, stackTrace: stackTrace, willRetryLater: retry),
      );
      if (retry) scheduleRetainedObjectCheck(delay: HeapDumpPolicy.waitAfterDumpFailed);
      _showRetainedCountNotification(objectCount: retainedReferenceCount, contentText: LeakSentryStrings.retainedDumpFailed);
      return null;
    }
  }

  /// The number of retained objects, once a GC has had the chance to collect
  /// the ones that only look retained because they haven't been collected yet.
  ///
  /// The GC is skipped when it can change nothing: every retained object became
  /// retained before the last forced GC started, so it has survived a full
  /// collection since, and the check is only going to wait. The GC always runs
  /// before a dump.
  Future<int> _retainedCountAfterGc(int retainedVisibleThreshold) async {
    final retainedReferenceCount = _tracker.retainedObjectCount;
    if (retainedReferenceCount == 0) return 0;
    if (_lastForcedGcSettledTheCount && !_wouldDump(retainedReferenceCount, retainedVisibleThreshold)) {
      _stats.forcedGcsSkipped++;
      return retainedReferenceCount;
    }
    await _runGc();
    return _tracker.retainedObjectCount;
  }

  bool get _lastForcedGcSettledTheCount {
    final lastGcStartedUptime = _lastGcStartedUptime;
    final newestRetainedUptime = _tracker.newestRetainedUptime;
    if (lastGcStartedUptime == null || newestRetainedUptime == null) return false;
    if (newestRetainedUptime > lastGcStartedUptime) return false;
    return _clock() - lastGcStartedUptime < HeapDumpPolicy.staleCountRefreshInterval;
  }

  /// Whether [_checkRetainedCount] would let the heap be dumped for this count.
  bool _wouldDump(int retainedKeysCount, int retainedVisibleThreshold) =>
      retainedKeysCount > 0 &&
      !(retainedKeysCount < retainedVisibleThreshold &&
          (_applicationVisible || _applicationInvisibleLessThanWatchPeriod));

  /// Runs a GC and remembers when it started, so that later checks can tell it
  /// already covered the objects that were retained by then.
  ///
  /// A GC that threw or never answered settled nothing, so it isn't remembered
  /// and the retry runs another. One that finished without being confirmed is:
  /// repeating it on every check would only repeat its cost (the fallback
  /// allocates for up to two seconds), and without a VM service the count it
  /// leaves is as settled as it can be made. It runs again after a minute, and
  /// before every dump.
  Future<void> _runGc() async {
    final startedUptime = _clock();
    final stopwatch = Stopwatch()..start();
    final confirmed = await _gcTrigger.runGc().timeout(_maxGcWait);
    _lastGcStartedUptime = startedUptime;
    _stats.forcedGcMicros += stopwatch.elapsedMicroseconds;
    if (confirmed) {
      _stats.forcedGcs++;
    } else {
      _stats.forcedGcFailures++;
    }
  }

  /// Returns true if there is nothing to dump for now: nothing is retained, or
  /// too few objects are and the app is visible or just became invisible.
  bool _checkRetainedCount(int retainedKeysCount, int retainedVisibleThreshold, [String? nopeReason]) {
    final countChanged = _lastDisplayedRetainedObjectCount != retainedKeysCount;
    _lastDisplayedRetainedObjectCount = retainedKeysCount;
    if (retainedKeysCount == 0) {
      if (countChanged) {
        LeakSentryLog.d(() => 'All retained objects have been garbage collected');
        _onRetainInstanceListener(const NoMoreObjectsEvent());
        _showNoMoreRetainedObjectNotification();
      }
      return true;
    }

    final applicationVisible = _applicationVisible;
    final applicationInvisibleLessThanWatchPeriod = _applicationInvisibleLessThanWatchPeriod;

    if (countChanged) {
      final String whatsNext;
      if (applicationVisible) {
        if (retainedKeysCount < retainedVisibleThreshold) {
          whatsNext = 'not dumping heap yet (app is visible & < $retainedVisibleThreshold threshold)';
        } else if (nopeReason != null) {
          whatsNext = 'would dump heap now (app is visible & >=$retainedVisibleThreshold threshold) but $nopeReason';
        } else {
          whatsNext = 'dumping heap now (app is visible & >=$retainedVisibleThreshold threshold)';
        }
      } else if (applicationInvisibleLessThanWatchPeriod) {
        final wait = _retainedDelay - (_clock() - _applicationInvisibleAt!);
        if (nopeReason != null) {
          whatsNext = 'would dump heap in ${wait.inMilliseconds} ms (app just became invisible) but $nopeReason';
        } else {
          whatsNext = 'dumping heap in ${wait.inMilliseconds} ms (app just became invisible)';
        }
      } else if (nopeReason != null) {
        whatsNext = 'would dump heap now (app is invisible) but $nopeReason';
      } else {
        whatsNext = 'dumping heap now (app is invisible)';
      }

      LeakSentryLog.d(() {
        final s = retainedKeysCount > 1 ? 's' : '';
        return 'Found $retainedKeysCount object$s retained, $whatsNext';
      });
    }

    if (retainedKeysCount < retainedVisibleThreshold) {
      if (applicationVisible || applicationInvisibleLessThanWatchPeriod) {
        if (countChanged) _onRetainInstanceListener(BelowThresholdEvent(retainedKeysCount));
        _showRetainedCountNotification(
          objectCount: retainedKeysCount,
          contentText: LeakSentryStrings.retainedVisible(retainedVisibleThreshold),
          reason: BelowThresholdEvent(retainedKeysCount),
        );
        scheduleRetainedObjectCheck(delay: HeapDumpPolicy.waitForObjectThreshold);
        return true;
      }
    }
    return false;
  }

  void _showNoMoreRetainedObjectNotification() {
    _dismissRetainedCountTask?.cancel();
    _notifier.showNoMoreRetainedObjects();
    _dismissRetainedCountTask = _scheduler.postDelayed(
      HeapDumpPolicy.dismissNoRetainedObjectNotice,
      _dismissRetainedCountNotification,
    );
  }

  void _showRetainedCountNotification({
    required int objectCount,
    required String contentText,
    RetainInstanceEvent? reason,
  }) {
    _dismissRetainedCountTask?.cancel();
    _dismissRetainedCountTask = null;
    _notifier.showRetainedCount(objectCount: objectCount, contentText: contentText, reason: reason);
  }

  void _dismissRetainedCountNotification() {
    _dismissRetainedCountTask?.cancel();
    _dismissRetainedCountTask = null;
    _notifier.dismissRetainedCount();
  }

  void _dismissNoRetainedOnRequestNotification() {
    _dismissNoRetainedOnRequestTask?.cancel();
    _dismissNoRetainedOnRequestTask = null;
    _notifier.dismissNoRetainedObjectsOnRequest();
  }
}

/// Runs jobs one after the other: the checks and the dump requests all go
/// through it. A failing job doesn't stop the ones after it.
class _SerialQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() job) {
    final result = _tail.then((_) => job());
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }
}
