import 'package:leak_sentry/core/gc_trigger.dart';

/// A [GcTrigger] that counts calls and lets a test decide what a GC does.
class FakeGcTrigger implements GcTrigger {
  int calls = 0;

  /// What [runGc] reports: whether a collection was confirmed.
  bool confirmed = true;

  /// Thrown by [runGc] when set.
  Object? error;

  /// Awaited inside [runGc], so a test can hold a GC open or make it collect
  /// something.
  Future<void> Function()? onRunGc;

  @override
  Future<bool> runGc() async {
    calls++;
    await onRunGc?.call();
    final failure = error;
    if (failure != null) throw failure;
    return confirmed;
  }
}
