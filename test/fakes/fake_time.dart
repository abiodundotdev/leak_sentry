import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/object_watcher/scheduler.dart';
import 'package:leak_sentry/object_watcher/uptime_clock.dart';

/// A clock and a scheduler that only move when a test says so, so no test
/// waits on real time.
class FakeTime implements Scheduler {
  Duration _now = Duration.zero;
  int _nextSequence = 0;
  final List<_FakeTask> _tasks = [];

  /// The current uptime. Pass it as the [UptimeClock] of what is under test.
  UptimeClock get clock => () => _now;

  Duration get now => _now;

  /// How many tasks are scheduled and haven't run or been cancelled.
  int get pendingCount => _tasks.length;

  /// How long from now each pending task is due, soonest first.
  List<Duration> get pendingDelays => [for (final task in _sorted()) task.due - _now];

  @override
  ScheduledTask postDelayed(Duration delay, void Function() task) {
    final fakeTask = _FakeTask(this, _now + delay, _nextSequence++, task);
    _tasks.add(fakeTask);
    return fakeTask;
  }

  /// Moves time forward without running anything async in between: every task
  /// that comes due runs, in order, one after the other. Use [elapse] when the
  /// code under test awaits.
  void advance(Duration duration) {
    final target = _now + duration;
    while (true) {
      final next = _nextDue(target);
      if (next == null) break;
      _run(next);
    }
    _moveTo(target);
  }

  /// Moves time forward, letting asynchronous work settle after each task that
  /// runs, so work scheduled by that work is seen at the right time.
  Future<void> elapse(Duration duration) async {
    final target = _now + duration;
    await pumpEventQueue();
    while (true) {
      final next = _nextDue(target);
      if (next == null) break;
      _run(next);
      await pumpEventQueue();
    }
    _moveTo(target);
    await pumpEventQueue();
  }

  // Time never goes back, even when code under test moved it on meanwhile.
  void _moveTo(Duration target) {
    if (target > _now) _now = target;
  }

  _FakeTask? _nextDue(Duration target) {
    final sorted = _sorted();
    if (sorted.isEmpty || sorted.first.due > target) return null;
    return sorted.first;
  }

  List<_FakeTask> _sorted() =>
      [..._tasks]..sort((a, b) => a.due != b.due ? a.due.compareTo(b.due) : a.sequence.compareTo(b.sequence));

  void _run(_FakeTask task) {
    _tasks.remove(task);
    if (task.due > _now) _now = task.due;
    task.run();
  }
}

class _FakeTask implements ScheduledTask {
  _FakeTask(this._time, this.due, this.sequence, this.run);

  final FakeTime _time;
  final Duration due;
  final int sequence;
  final void Function() run;

  @override
  void cancel() => _time._tasks.remove(this);
}
