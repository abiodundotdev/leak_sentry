import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/gc_trigger.dart';
import 'package:leak_sentry/core/heap_dump_control.dart';
import 'package:leak_sentry/core/heap_dump_policy.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/core/internal_leak_sentry.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';
import 'package:leak_sentry/models/resource_token.dart';
import 'package:leak_sentry/object_watcher/object_event_router.dart';

import '../fakes/fake_gc_trigger.dart';
import '../fakes/fake_object_finalizer.dart';
import '../fakes/fake_time.dart';
import '../fakes/fake_visibility_tracker.dart';
import '../fakes/fake_vm_bridge.dart';
import '../fakes/recording_notifier.dart';

/// An [InternalLeakSentry] wired to fakes: time, GC, VM, visibility and
/// notices are all driven by the test, and no real timer is ever created.
class EngineFixture {
  EngineFixture({
    bool release = false,
    bool web = false,
    LeakCatalog? catalog,
    GcTrigger? gc,
    String? Function()? testEnvironment,
    bool overrideTestEnvironment = true,
    Duration listenerWait = HeapDumpPolicy.maxListenerWait,
    Duration analysisWait = HeapDumpPolicy.maxAnalysisWait,
  }) {
    this.gc = gc ?? fakeGc;
    engine = InternalLeakSentry(
      clock: time.clock,
      scheduler: time,
      vm: vm,
      gcTrigger: this.gc,
      router: router,
      visibilityTracker: visibility,
      notifier: notifier,
      wallClock: wallNow,
      catalog: catalog,
      testEnvironment: overrideTestEnvironment ? (testEnvironment ?? () => null) : null,
      isReleaseBuild: release,
      isWeb: web,
      listenerWait: listenerWait,
      analysisWait: analysisWait,
      resourceFinalizerFactory: (callback) => finalizer = FakeObjectFinalizer<ResourceToken>(callback),
    );
    engine.events.listen(events.add);
  }

  /// Wall-clock time as the engine shows it: it starts here and moves with [time].
  static final DateTime epoch = DateTime(2026, 1, 1, 12);

  DateTime wallNow() => epoch.add(time.now);

  final time = FakeTime();
  final vm = FakeVmBridge();
  final fakeGc = FakeGcTrigger();
  final visibility = FakeVisibilityTracker();
  final router = ObjectEventRouter();
  final notifier = RecordingNotifier();
  final events = <LeakSentryEvent>[];
  late final GcTrigger gc;
  late final InternalLeakSentry engine;
  late FakeObjectFinalizer<ResourceToken> finalizer;

  /// Lets the engine's asynchronous work, including the analysis, finish.
  Future<void> settle() async {
    await time.elapse(Duration.zero);
  }

  Iterable<T> eventsOf<T extends LeakSentryEvent>() => events.whereType<T>();

  /// Waits, in real time, for an event that depends on a real GC to be sent.
  Future<T> waitForEvent<T extends LeakSentryEvent>() async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (eventsOf<T>().isEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('no $T was sent');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return eventsOf<T>().first;
  }
}

/// Makes an [EngineFixture]'s engine the one the `LeakSentry` API and widgets
/// use. Undo it with `LeakSentry.resetForTesting`.
abstract final class InternalLeakSentryHolder {
  static void use(EngineFixture fixture) => InternalLeakSentry.instance = fixture.engine;
}

/// What keeps the engine of [f] from scanning by itself. Fails if nothing does.
HeapDumpBlock blockOf(EngineFixture f) {
  final permission = f.engine.heapDumpPermission;
  if (permission is! Nope) fail('scanning is allowed');
  return permission.block;
}
