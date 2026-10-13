import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:leak_sentry/core/leak_sentry_log.dart';
import 'package:leak_sentry/models/leak_sentry_internal.dart';
import 'package:leak_sentry/models/leak_sentry_stats.dart';
import 'package:leak_sentry/models/object_creation_sites.dart';

/// A registration made with [ObjectEventRouter.listenForDisposal].
class ObjectEventSubscription {
  ObjectEventSubscription._(this._router, this._handler);

  final ObjectEventRouter _router;
  final _DisposalHandler _handler;

  void cancel() => _router._remove(_handler);
}

/// The one listener LeakSentry has on `FlutterMemoryAllocations`, shared by
/// every watcher.
///
/// Flutter reports thousands of object events a second (elements, render
/// objects, layers), so each watcher adding its own listener would repeat the
/// same filtering for every event. Here an event costs one type check per
/// registered watcher, and only objects some watcher cares about get a
/// creation stack captured.
///
/// Flutter only dispatches these events when `kFlutterMemoryAllocationsEnabled`
/// is true, which is the default in debug builds only.
///
/// Objects that are [LeakSentryInternal] are ignored, so LeakSentry's own
/// screens are never watched.
class ObjectEventRouter {
  ObjectEventRouter({FlutterMemoryAllocations? allocations, ObjectCreationSites? creationSites, LeakSentryStats? stats})
    : _allocations = allocations ?? FlutterMemoryAllocations.instance,
      creationSites = creationSites ?? ObjectCreationSites(),
      stats = stats ?? LeakSentryStats();

  /// The router default watchers use.
  static final ObjectEventRouter shared = ObjectEventRouter();

  /// Render-tree and engine objects Flutter creates thousands of times a
  /// second. Framework internals create them, so a creation stack would hold no
  /// application frames anyway, and capturing one each time isn't worth it.
  static const Set<String> _highChurnClassNames = {
    'Element',
    'RenderObject',
    'Layer',
    'PipelineOwner',
    '_LocalSemanticsHandle',
  };

  final FlutterMemoryAllocations _allocations;

  /// Where objects were created, taken when the object is watched.
  final ObjectCreationSites creationSites;

  /// What handling object events has cost so far.
  final LeakSentryStats stats;

  // Replaced, never mutated, so the event loop below iterates a stable list.
  List<_DisposalHandler> _handlers = const [];
  bool _listening = false;

  // Objects that are created and then collected without ever being disposed
  // leave an entry in `creationSites`. Dropping those every so often, in
  // proportion to what is alive, keeps the cost per event constant.
  static const int _minRecordsBetweenPrunes = 2048;
  int _recordedSincePrune = 0;
  int _recordsBetweenPrunes = _minRecordsBetweenPrunes;

  /// Calls [onDisposed] for every object of type [T] that Flutter reports
  /// disposed. Objects of that type also get a creation stack recorded.
  ObjectEventSubscription listenForDisposal<T extends Object>(void Function(T object) onDisposed) {
    final handler = _DisposalHandler((object) => object is T, (object) => onDisposed(object as T));
    _handlers = [..._handlers, handler];
    _startListening();
    return ObjectEventSubscription._(this, handler);
  }

  void _remove(_DisposalHandler handler) {
    if (!_handlers.contains(handler)) return;
    _handlers = [
      for (final existing in _handlers)
        if (existing != handler) existing,
    ];
    if (_handlers.isEmpty) _stopListening();
  }

  void _startListening() {
    if (_listening) return;
    _allocations.addListener(_onEvent);
    _listening = true;
  }

  void _stopListening() {
    if (!_listening) return;
    _allocations.removeListener(_onEvent);
    _listening = false;
    creationSites.clear();
  }

  void _onEvent(ObjectEvent event) {
    // A listener that throws would surface inside the app's own `dispose()`.
    try {
      if (event is ObjectCreated) {
        _onCreated(event);
      } else if (event is ObjectDisposed) {
        _onDisposed(event.object);
      }
    } catch (error, stackTrace) {
      LeakSentryLog.d(() => 'Failed to handle an object event', error: error, stackTrace: stackTrace);
    }
  }

  void _onCreated(ObjectCreated event) {
    if (event.library == 'dart:ui' || _highChurnClassNames.contains(event.className)) return;
    final object = event.object;
    if (object is LeakSentryInternal) return;
    if (!_handlers.any((handler) => handler.matches(object))) return;
    final stopwatch = Stopwatch()..start();
    creationSites.record(object, StackTrace.current);
    if (++_recordedSincePrune >= _recordsBetweenPrunes) {
      creationSites.pruneCollected();
      _recordedSincePrune = 0;
      _recordsBetweenPrunes = math.max(_minRecordsBetweenPrunes, creationSites.length);
    }
    stats.creationEvents++;
    stats.creationMicros += stopwatch.elapsedMicroseconds;
  }

  void _onDisposed(Object object) {
    if (object is LeakSentryInternal) return;
    final stopwatch = Stopwatch()..start();
    for (final handler in _handlers) {
      if (!handler.matches(object)) continue;
      // Watchers are independent: one that fails must not stop the others from
      // seeing the same object.
      try {
        handler.onDisposed(object);
      } catch (error, stackTrace) {
        LeakSentryLog.d(
          () => 'A watcher failed on a disposed ${object.runtimeType}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    stats.disposalEvents++;
    stats.disposalMicros += stopwatch.elapsedMicroseconds;
  }
}

class _DisposalHandler {
  _DisposalHandler(this.matches, this.onDisposed);

  final bool Function(Object object) matches;
  final void Function(Object object) onDisposed;
}
