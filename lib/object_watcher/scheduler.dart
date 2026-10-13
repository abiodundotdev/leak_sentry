import 'dart:async';

/// A task posted with [Scheduler.postDelayed] that has not run yet.
abstract interface class ScheduledTask {
  void cancel();
}

/// Runs work later. It exists so tests can drive time by hand.
abstract interface class Scheduler {
  ScheduledTask postDelayed(Duration delay, void Function() task);
}

/// The real [Scheduler], backed by [Timer].
class TimerScheduler implements Scheduler {
  const TimerScheduler();

  @override
  ScheduledTask postDelayed(Duration delay, void Function() task) => _TimerTask(Timer(delay, task));
}

class _TimerTask implements ScheduledTask {
  _TimerTask(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}
