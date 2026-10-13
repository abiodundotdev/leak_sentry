import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/gc_trigger.dart';

import 'fakes/fake_vm_bridge.dart';
import 'helpers/capture_log.dart';

void main() {
  late FakeVmBridge vm;

  setUp(() => vm = FakeVmBridge());

  test('a collection the VM ran, that the barrier saw, is confirmed without any allocating', () async {
    var barrier = 10;
    var reads = 0;
    vm.onForceGc = () async => barrier += 2;
    final trigger = VmGcTrigger(
      vm: vm,
      reachabilityBarrier: () {
        reads++;
        return barrier;
      },
    );

    expect(await trigger.runGc(), isTrue);

    expect(vm.forceGcCalls, 1);
    expect(reads, 2, reason: 'once before and once after the VM ran it, nothing more');
  });

  test('falls back to allocating when the VM does not confirm, and succeeds once the barrier has moved on', () async {
    var barrier = 0;
    vm.forceGcSucceeds = false;
    final trigger = VmGcTrigger(vm: vm, reachabilityBarrier: () => barrier++);

    expect(await trigger.runGc(), isTrue);

    expect(vm.forceGcCalls, 1);
  });

  test('a confirmation the barrier contradicts is not trusted, and falls back too', () async {
    final log = captureLog();
    vm.forceGcSucceeds = true; // the VM says yes, but the barrier never moves
    final trigger = VmGcTrigger(
      vm: vm,
      reachabilityBarrier: () => 7,
      fallbackTimeout: const Duration(milliseconds: 30),
    );

    expect(await trigger.runGc(), isFalse);

    expect(log.lines.single, startsWith('Could not force a garbage collection'));
  });

  test('gives up after the timeout and says it was not confirmed', () async {
    vm.forceGcSucceeds = false;
    final trigger = VmGcTrigger(
      vm: vm,
      reachabilityBarrier: () => 0,
      fallbackTimeout: const Duration(milliseconds: 30),
    );

    final stopwatch = Stopwatch()..start();
    expect(await trigger.runGc(), isFalse);

    expect(stopwatch.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 30)));
  });

  test('warns about an unconfirmed collection once, not every time', () async {
    final log = captureLog();
    vm.forceGcSucceeds = false;
    final trigger = VmGcTrigger(
      vm: vm,
      reachabilityBarrier: () => 0,
      fallbackTimeout: const Duration(milliseconds: 10),
    );

    await trigger.runGc();
    await trigger.runGc();
    await trigger.runGc();

    expect(log.lines, hasLength(1));
  });

  test('the fallback needs the barrier to move three cycles, not one', () async {
    // The barrier also ticks when concurrent marking starts, so one tick is not
    // a whole collection.
    var barrier = 0;
    var reads = 0;
    vm.forceGcSucceeds = false;
    final trigger = VmGcTrigger(
      vm: vm,
      reachabilityBarrier: () {
        reads++;
        // Moves by one every other read after the first.
        return reads < 2 ? 0 : barrier = reads ~/ 2;
      },
    );

    expect(await trigger.runGc(), isTrue);

    expect(barrier, greaterThanOrEqualTo(3));
  });

  test('on the web it asks the VM for nothing and says no collection was confirmed', () async {
    final log = captureLog();
    final trigger = VmGcTrigger(vm: vm, isWeb: true, reachabilityBarrier: () => throw StateError('no barrier on the web'));

    expect(await trigger.runGc(), isFalse);

    expect(vm.forceGcCalls, 0);
    expect(log.lines.single, startsWith('Could not force a garbage collection'));
  });

  test('a VM bridge that throws is an unconfirmed collection, not a crash, and the fallback still runs', () async {
    final log = captureLog();
    var barrier = 0;
    vm.onForceGc = () async => throw StateError('dart:isolate is not supported');
    final trigger = VmGcTrigger(vm: vm, reachabilityBarrier: () => barrier++);

    expect(await trigger.runGc(), isTrue, reason: 'the allocation fallback moved the barrier');

    expect(log.lines, contains('Asking the VM for a garbage collection failed'));
    expect(log.errors.single, isA<StateError>());
  });

  test('a VM bridge that throws, with nothing to fall back on, says it was not confirmed', () async {
    captureLog();
    vm.onForceGc = () async => throw StateError('dart:isolate is not supported');
    final trigger = VmGcTrigger(
      vm: vm,
      reachabilityBarrier: () => 0,
      fallbackTimeout: const Duration(milliseconds: 20),
    );

    expect(await trigger.runGc(), isFalse);
  });

  test('works with the real VM barrier', () async {
    // No VM service is available in a unit test, so the VM does not confirm and
    // the trigger collects by allocating, which the real barrier then sees.
    vm.forceGcSucceeds = false;
    final trigger = VmGcTrigger(vm: vm, fallbackTimeout: const Duration(seconds: 20));

    expect(await trigger.runGc(), isTrue);
  });
}
