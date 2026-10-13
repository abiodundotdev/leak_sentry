import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/object_watcher/delayed_executor.dart';

import 'fakes/fake_time.dart';
import 'helpers/capture_log.dart';

void main() {
  late FakeTime time;
  late SchedulerDelayedExecutor executor;
  late List<String> ran;

  setUp(() {
    time = FakeTime();
    executor = SchedulerDelayedExecutor(scheduler: time, clock: time.clock);
    ran = [];
  });

  test('runs a task once its delay has passed, and not before', () {
    executor.executeWithDelay(const Duration(seconds: 5), () => ran.add('a'));

    time.advance(const Duration(milliseconds: 4999));
    expect(ran, isEmpty);

    time.advance(const Duration(milliseconds: 1));
    expect(ran, ['a']);
    expect(executor.pendingCount, 0);
  });

  test('keeps one timer however many tasks are waiting', () {
    for (var i = 0; i < 100; i++) {
      executor.executeWithDelay(const Duration(seconds: 5), () {});
    }

    expect(executor.pendingCount, 100);
    expect(time.pendingCount, 1);
  });

  test('runs tasks in the order they are due', () {
    executor.executeWithDelay(const Duration(seconds: 3), () => ran.add('late'));
    executor.executeWithDelay(const Duration(seconds: 1), () => ran.add('early'));
    executor.executeWithDelay(const Duration(seconds: 2), () => ran.add('middle'));

    time.advance(const Duration(seconds: 3));

    expect(ran, ['early', 'middle', 'late']);
  });

  test('runs tasks that are due together in the order they arrived', () {
    for (final name in ['a', 'b', 'c']) {
      executor.executeWithDelay(const Duration(seconds: 1), () => ran.add(name));
    }

    time.advance(const Duration(seconds: 1));

    expect(ran, ['a', 'b', 'c']);
    expect(time.pendingCount, 0);
  });

  test('a constant delay makes tasks run at their own times, each after the same wait', () {
    executor.executeWithDelay(const Duration(seconds: 5), () => ran.add('first'));
    time.advance(const Duration(seconds: 2));
    executor.executeWithDelay(const Duration(seconds: 5), () => ran.add('second'));

    time.advance(const Duration(seconds: 3));
    expect(ran, ['first']);

    time.advance(const Duration(seconds: 2));
    expect(ran, ['first', 'second']);
  });

  test('a task due sooner than the one the timer waits for moves the timer earlier', () {
    executor.executeWithDelay(const Duration(seconds: 10), () => ran.add('slow'));
    expect(time.pendingDelays, [const Duration(seconds: 10)]);

    executor.executeWithDelay(const Duration(seconds: 1), () => ran.add('fast'));

    expect(time.pendingCount, 1, reason: 'the old timer is replaced, not kept as well');
    expect(time.pendingDelays, [const Duration(seconds: 1)]);
    time.advance(const Duration(seconds: 1));
    expect(ran, ['fast']);
    expect(time.pendingDelays, [const Duration(seconds: 9)]);
  });

  test('a task due later than the one the timer waits for leaves the timer alone', () {
    executor.executeWithDelay(const Duration(seconds: 1), () {});

    executor.executeWithDelay(const Duration(seconds: 5), () {});

    expect(time.pendingDelays, [const Duration(seconds: 1)]);
  });

  test('every task that is due when the timer finally runs is run in that one go', () {
    var clockNow = Duration.zero;
    final lagging = SchedulerDelayedExecutor(scheduler: time, clock: () => clockNow);
    lagging.executeWithDelay(const Duration(seconds: 1), () => ran.add('a'));
    lagging.executeWithDelay(const Duration(seconds: 2), () => ran.add('b'));
    lagging.executeWithDelay(const Duration(seconds: 9), () => ran.add('c'));

    clockNow = const Duration(seconds: 3); // the timer fires late
    time.advance(const Duration(seconds: 1));

    expect(ran, ['a', 'b']);
    expect(lagging.pendingCount, 1);
    expect(time.pendingCount, 1, reason: 'one timer is left for the task still waiting');
  });

  test('a task can schedule another', () {
    executor.executeWithDelay(const Duration(seconds: 1), () {
      ran.add('first');
      executor.executeWithDelay(const Duration(seconds: 1), () => ran.add('second'));
    });

    time.advance(const Duration(seconds: 1));
    expect(ran, ['first']);

    time.advance(const Duration(seconds: 1));
    expect(ran, ['first', 'second']);
  });

  test('a task that throws does not hold back the others that are due', () {
    final log = captureLog();
    executor.executeWithDelay(const Duration(seconds: 1), () => throw StateError('boom'));
    executor.executeWithDelay(const Duration(seconds: 1), () => ran.add('after'));
    executor.executeWithDelay(const Duration(seconds: 2), () => ran.add('later'));

    time.advance(const Duration(seconds: 2));

    expect(ran, ['after', 'later']);
    expect(log.lines, contains('A delayed task failed'));
    expect(log.errors.single, isA<StateError>());
  });

  test('a task with no delay runs on the next turn of the scheduler', () {
    executor.executeWithDelay(Duration.zero, () => ran.add('now'));

    expect(ran, isEmpty);
    time.advance(Duration.zero);
    expect(ran, ['now']);
  });

  test('cancelAll drops every task and the timer', () {
    executor.executeWithDelay(const Duration(seconds: 1), () => ran.add('a'));
    executor.executeWithDelay(const Duration(seconds: 2), () => ran.add('b'));

    executor.cancelAll();

    expect(executor.pendingCount, 0);
    expect(time.pendingCount, 0);
    time.advance(const Duration(seconds: 10));
    expect(ran, isEmpty);
  });

  test('works again after cancelAll', () {
    executor.executeWithDelay(const Duration(seconds: 1), () => ran.add('dropped'));
    executor.cancelAll();

    executor.executeWithDelay(const Duration(seconds: 1), () => ran.add('kept'));
    time.advance(const Duration(seconds: 1));

    expect(ran, ['kept']);
  });
}
