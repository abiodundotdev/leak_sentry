import 'dart:collection';

import 'package:leak_sentry/core/leak_sentry_log.dart';
import 'package:leak_sentry/object_watcher/scheduler.dart';
import 'package:leak_sentry/object_watcher/uptime_clock.dart';

/// Runs a task after a delay.
abstract interface class DelayedExecutor {
  void executeWithDelay(Duration delayUptime, void Function() task);
}

/// A [DelayedExecutor] that keeps every pending task in one queue and has a
/// single task scheduled on the [Scheduler], for whichever is due first.
///
/// A Dart `Timer` per pending task would cost a heap allocation and a timer-heap
/// insertion each, and a list of 500 disposed items would create 500 of them.
/// With the delay constant, tasks come due in the order they were added, so one
/// timer is enough and every task still runs at its own due time.
class SchedulerDelayedExecutor implements DelayedExecutor {
  SchedulerDelayedExecutor({required Scheduler scheduler, required UptimeClock clock})
    : _scheduler = scheduler,
      _clock = clock;

  final Scheduler _scheduler;
  final UptimeClock _clock;

  // Ordered by due time, then by arrival.
  final SplayTreeMap<(Duration, int), void Function()> _queue = SplayTreeMap(_compare);
  int _nextSequence = 0;
  ScheduledTask? _scheduled;
  Duration? _scheduledDue;

  /// Tasks that haven't run yet.
  int get pendingCount => _queue.length;

  @override
  void executeWithDelay(Duration delayUptime, void Function() task) {
    final due = _clock() + delayUptime;
    _queue[(due, _nextSequence++)] = task;
    final scheduledDue = _scheduledDue;
    if (scheduledDue == null || due < scheduledDue) _reschedule();
  }

  /// Drops every pending task.
  void cancelAll() {
    _queue.clear();
    _scheduled?.cancel();
    _scheduled = null;
    _scheduledDue = null;
  }

  void _reschedule() {
    _scheduled?.cancel();
    _scheduled = null;
    _scheduledDue = null;
    if (_queue.isEmpty) return;
    final due = _queue.firstKey()!.$1;
    var delay = due - _clock();
    if (delay.isNegative) delay = Duration.zero;
    _scheduledDue = due;
    _scheduled = _scheduler.postDelayed(delay, _runDueTasks);
  }

  void _runDueTasks() {
    _scheduled = null;
    _scheduledDue = null;
    try {
      final now = _clock();
      while (_queue.isNotEmpty) {
        final key = _queue.firstKey()!;
        if (key.$1 > now) break;
        final task = _queue.remove(key)!;
        try {
          task();
        } catch (error, stackTrace) {
          // One failing task must not hold back the others that are due.
          LeakSentryLog.d(() => 'A delayed task failed', error: error, stackTrace: stackTrace);
        }
      }
    } finally {
      _reschedule();
    }
  }

  static int _compare((Duration, int) a, (Duration, int) b) {
    final byDue = a.$1.compareTo(b.$1);
    return byDue != 0 ? byDue : a.$2.compareTo(b.$2);
  }
}
