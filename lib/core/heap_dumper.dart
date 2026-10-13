import 'package:leak_sentry/models/vm_bridge.dart';
import 'package:leak_sentry/object_watcher/keyed_weak_reference.dart';
import 'package:leak_sentry/object_watcher/retained_object_tracker.dart';

/// What a heap dump hands to the analysis: the retained objects, captured
/// without holding any of them.
///
/// The dump is the retained set captured at one moment (with VM ids so their
/// retaining paths can be looked up); a real heap snapshot joins it later.
class RetainedObjectsDump {
  const RetainedObjectsDump({required this.objects, required this.dumpUptime, this.isolateId});

  final List<RetainedObjectSnapshot> objects;

  /// When the dump was taken, on the tracker's `UptimeClock`.
  final Duration dumpUptime;

  /// The VM service id of the isolate the objects live in, if known.
  final String? isolateId;
}

/// Dumps the heap.
abstract interface class HeapDumper {
  Future<RetainedObjectsDump> dumpHeap();
}

/// The default [HeapDumper]: captures the retained set.
class RetainedSetHeapDumper implements HeapDumper {
  RetainedSetHeapDumper({
    required WeakReferenceRetainedObjectTracker tracker,
    required VmBridge vm,
    required Duration Function() uptime,
  }) : _tracker = tracker,
       _vm = vm,
       _uptime = uptime;

  final WeakReferenceRetainedObjectTracker _tracker;
  final VmBridge _vm;
  final Duration Function() _uptime;

  @override
  Future<RetainedObjectsDump> dumpHeap() async {
    final dumpUptime = _uptime();
    final objects = _tracker.snapshotRetainedObjects(objectIdOf: _vm.objectIdOf);
    return RetainedObjectsDump(objects: objects, dumpUptime: dumpUptime, isolateId: _vm.isolateId);
  }
}
