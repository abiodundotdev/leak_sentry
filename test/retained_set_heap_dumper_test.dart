import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/object_watcher/retained_object_tracker.dart';

import 'fakes/fake_time.dart';
import 'fakes/fake_vm_bridge.dart';

class _Thing {}

void main() {
  late FakeTime time;
  late WeakReferenceRetainedObjectTracker tracker;
  late FakeVmBridge vm;
  late RetainedSetHeapDumper dumper;

  setUp(() {
    time = FakeTime();
    tracker = WeakReferenceRetainedObjectTracker(clock: time.clock, onObjectRetained: () {});
    vm = FakeVmBridge();
    dumper = RetainedSetHeapDumper(tracker: tracker, vm: vm, uptime: time.clock);
  });

  test('captures the retained objects, not the ones still waiting out their delay', () async {
    final retained = _Thing();
    final waiting = _Thing();
    tracker.expectDeletionOnTriggerFor(retained, 'retained').markRetainedIfStronglyReachable();
    tracker.expectDeletionOnTriggerFor(waiting, 'waiting');

    final dump = await dumper.dumpHeap();

    expect(dump.objects.map((object) => object.description), ['retained']);
    expect(retained, isNotNull);
    expect(waiting, isNotNull);
  });

  test('says when it was taken and in which isolate', () async {
    time.advance(const Duration(seconds: 42));

    final dump = await dumper.dumpHeap();

    expect(dump.dumpUptime, const Duration(seconds: 42));
    expect(dump.isolateId, 'isolates/1');
  });

  test('is empty when nothing is retained', () async {
    final dump = await dumper.dumpHeap();

    expect(dump.objects, isEmpty);
  });

  test('leaves the tracker as it was: clearing after a dump is the trigger\'s job', () async {
    final retained = _Thing();
    tracker.expectDeletionOnTriggerFor(retained, 'retained').markRetainedIfStronglyReachable();

    await dumper.dumpHeap();

    expect(tracker.retainedObjectCount, 1);
  });

  test('hands the VM ids over lazily, so nothing is pinned by taking a dump', () async {
    final retained = _Thing();
    tracker.expectDeletionOnTriggerFor(retained, 'retained').markRetainedIfStronglyReachable();
    final asked = <Object>[];
    final recording = RetainedSetHeapDumper(
      tracker: tracker,
      vm: _RecordingIdVm(asked),
      uptime: time.clock,
    );

    final dump = await recording.dumpHeap();
    expect(asked, isEmpty);

    expect(dump.objects.single.resolveVmObjectId(), 'objects/recorded');
    expect(asked.single, same(retained));
  });
}

class _RecordingIdVm extends FakeVmBridge {
  _RecordingIdVm(this._asked);

  final List<Object> _asked;

  @override
  String? objectIdOf(Object object) {
    _asked.add(object);
    return 'objects/recorded';
  }
}
