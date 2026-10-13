import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/object_watcher/uptime_clock.dart';

/// A [HeapDumper] that records dumps and can be told to fail.
class FakeHeapDumper implements HeapDumper {
  FakeHeapDumper(this._clock);

  final UptimeClock _clock;

  int calls = 0;

  /// The dumps that succeeded, in order.
  final List<RetainedObjectsDump> dumps = [];

  /// Thrown by [dumpHeap] when set.
  Object? error;

  /// Awaited inside [dumpHeap], so a test can hold a dump open.
  Future<void> Function()? onDump;

  @override
  Future<RetainedObjectsDump> dumpHeap() async {
    calls++;
    await onDump?.call();
    final failure = error;
    if (failure != null) throw failure;
    final dump = RetainedObjectsDump(objects: const [], dumpUptime: _clock());
    dumps.add(dump);
    return dump;
  }
}
