import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:leak_sentry/core/leak_sentry_log.dart';
import 'package:leak_sentry/models/vm_bridge.dart';

/// Forces a garbage collection.
abstract interface class GcTrigger {
  /// Runs a full collection. Returns whether one was confirmed to have run.
  Future<bool> runGc();
}

/// A [GcTrigger] for the Dart VM.
///
/// Dart has no public way to ask for a collection, and no need to wait
/// afterwards: weak references are cleared inside the collection itself, so a
/// [WeakReference] already reads null as soon as the collection has finished.
///
/// The collection is requested from the VM service (`_collectAllGarbage`, a
/// private call that is not on every VM build). Whether it really ran is
/// checked with the VM's reachability barrier, which advances each time the old
/// generation is collected. Without a VM service the trigger allocates garbage
/// until the barrier has advanced past a whole collection cycle; that is a best
/// effort, and it gives up after [fallbackTimeout].
class VmGcTrigger implements GcTrigger {
  VmGcTrigger({
    required VmBridge vm,
    int Function()? reachabilityBarrier,
    this.fallbackTimeout = const Duration(seconds: 2),
    bool? isWeb,
  }) : _vm = vm,
       _barrier = reachabilityBarrier ?? _vmReachabilityBarrier,
       _isWeb = isWeb ?? kIsWeb;

  /// The barrier ticks when concurrent marking starts as well as when it
  /// finishes, so a cycle that was already running when the objects became
  /// unreachable takes three ticks to be followed by a whole one.
  static const int _cyclesWithoutVmService = 3;

  final VmBridge _vm;
  final int Function() _barrier;
  final bool _isWeb;

  /// How long to keep allocating when the VM service can't run the collection.
  final Duration fallbackTimeout;

  bool _warnedUnconfirmed = false;

  static int _vmReachabilityBarrier() => developer.reachabilityBarrier;

  @override
  Future<bool> runGc() async {
    // No GC can be asked for, or told apart from a natural one, on the web.
    final confirmed = !_isWeb && await _collect();
    if (!confirmed && !_warnedUnconfirmed) {
      _warnedUnconfirmed = true;
      LeakSentryLog.d(
        () =>
            'Could not force a garbage collection (no VM service, or the VM did not confirm one). '
            'Retained objects may include some the VM has not collected yet.',
      );
    }
    return confirmed;
  }

  Future<bool> _collect() async {
    final before = _barrier();
    var requested = false;
    try {
      requested = await _vm.forceGc();
    } catch (error, stackTrace) {
      // A bridge that fails is a GC that was not confirmed, not a crash.
      LeakSentryLog.d(() => 'Asking the VM for a garbage collection failed', error: error, stackTrace: stackTrace);
    }
    if (requested && _barrier() > before) return true;
    return _collectByAllocationPressure(before);
  }

  Future<bool> _collectByAllocationPressure(int before) async {
    final target = before + _cyclesWithoutVmService;
    final stopwatch = Stopwatch()..start();
    // Kept so the allocations are not optimised away, and bounded so they
    // become garbage as the list turns over.
    final garbage = <List<int>>[];
    while (_barrier() < target) {
      if (stopwatch.elapsed > fallbackTimeout) return false;
      // Yielding lets frames run between rounds of allocation.
      await Future<void>.delayed(Duration.zero);
      garbage.add(List<int>.generate(30000, (n) => n));
      if (garbage.length > 100) garbage.removeAt(0);
    }
    return true;
  }
}
