import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/models/leak_sentry_internal.dart';
import 'package:leak_sentry/models/leak_sentry_stats.dart';
import 'package:leak_sentry/object_watcher/object_event_router.dart';

import 'helpers/capture_log.dart';
import 'helpers/force_gc.dart';

class _Widgety {}

class _Other {}

class _OwnWidgety extends _Widgety implements LeakSentryInternal {}

// Each creation is dispatched from its own function, so the report can point at
// a line of this file.
_Widgety _createWidgety(ObjectEventRouter router) {
  final object = _Widgety();
  _dispatchCreated(object, className: '_Widgety');
  return object;
}

void _dispatchCreated(Object object, {String className = 'Whatever', String library = 'package:app/app.dart'}) =>
    FlutterMemoryAllocations.instance.dispatchObjectEvent(
      ObjectCreated(library: library, className: className, object: object),
    );

void _dispatchDisposed(Object object) =>
    FlutterMemoryAllocations.instance.dispatchObjectEvent(ObjectDisposed(object: object));

void main() {
  late ObjectEventRouter router;
  late LeakSentryStats stats;
  late List<ObjectEventSubscription> subscriptions;

  ObjectEventSubscription listen<T extends Object>(void Function(T) onDisposed) {
    final subscription = router.listenForDisposal<T>(onDisposed);
    subscriptions.add(subscription);
    return subscription;
  }

  setUp(() {
    stats = LeakSentryStats();
    router = ObjectEventRouter(stats: stats);
    subscriptions = [];
  });

  tearDown(() {
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
  });

  group('disposal', () {
    test('calls the handler for an object of its type, with the object', () {
      final seen = <_Widgety>[];
      listen<_Widgety>(seen.add);
      final object = _Widgety();

      _dispatchDisposed(object);

      expect(seen.single, same(object));
    });

    test('ignores objects of other types', () {
      final seen = <_Widgety>[];
      listen<_Widgety>(seen.add);

      _dispatchDisposed(_Other());

      expect(seen, isEmpty);
    });

    test('ignores LeakSentry\'s own objects, even of a type a handler asks for', () {
      final seen = <_Widgety>[];
      listen<_Widgety>(seen.add);
      final own = _OwnWidgety();
      final theirs = _Widgety();

      _dispatchDisposed(own);
      _dispatchDisposed(theirs);

      expect(seen.single, same(theirs));
      expect(stats.disposalEvents, 1, reason: 'the own object cost nothing');
    });

    test('a handler for every object still never sees LeakSentry\'s own', () {
      final seen = <Object>[];
      listen<Object>(seen.add);

      _dispatchDisposed(_OwnWidgety());

      expect(seen, isEmpty);
    });

    test('a handler for a supertype gets its subtypes', () {
      final seen = <Object>[];
      listen<Object>(seen.add);

      _dispatchDisposed(_Other());
      _dispatchDisposed(_Widgety());

      expect(seen, hasLength(2));
    });

    test('every matching handler is called', () {
      var first = 0;
      var second = 0;
      listen<_Widgety>((_) => first++);
      listen<_Widgety>((_) => second++);

      _dispatchDisposed(_Widgety());

      expect([first, second], [1, 1]);
    });

    test('a cancelled handler is no longer called, the others still are', () {
      var cancelled = 0;
      var kept = 0;
      final subscription = listen<_Widgety>((_) => cancelled++);
      listen<_Widgety>((_) => kept++);

      subscription.cancel();
      _dispatchDisposed(_Widgety());

      expect([cancelled, kept], [0, 1]);
    });

    test('cancelling twice is harmless', () {
      var calls = 0;
      final subscription = listen<_Widgety>((_) => calls++);

      subscription.cancel();
      subscription.cancel();
      _dispatchDisposed(_Widgety());

      expect(calls, 0);
    });

    test('stops listening to Flutter once the last handler is cancelled, and starts again after', () {
      final baseline = FlutterMemoryAllocations.instance.hasListeners;
      final subscription = router.listenForDisposal<_Widgety>((_) {});
      expect(FlutterMemoryAllocations.instance.hasListeners, isTrue);

      subscription.cancel();
      expect(FlutterMemoryAllocations.instance.hasListeners, baseline);

      var calls = 0;
      listen<_Widgety>((_) => calls++);
      _dispatchDisposed(_Widgety());
      expect(calls, 1);
    });

    test('a handler that throws is logged, and neither the other handlers nor the app are affected', () {
      final log = captureLog();
      var reached = 0;
      listen<_Widgety>((_) => throw StateError('boom'));
      listen<_Widgety>((_) => reached++);

      // The error must not escape into the app's own dispose().
      expect(() => _dispatchDisposed(_Widgety()), returnsNormally);

      expect(reached, 1);
      expect(log.lines, contains('A watcher failed on a disposed _Widgety'));
      expect(log.errors.single, isA<StateError>());
    });

    test('counts the events it handled, and the time they took', () {
      listen<_Widgety>((_) {});

      _dispatchDisposed(_Widgety());
      _dispatchDisposed(_Other());

      expect(stats.disposalEvents, 2);
      expect(stats.disposalMicros, greaterThanOrEqualTo(0));
    });
  });

  group('creation', () {
    test('records where an object of a watched type was created', () {
      listen<_Widgety>((_) {});

      final object = _createWidgety(router);

      final stack = router.creationSites.take(object);
      expect(stack, isNotNull);
      expect(stack.toString(), contains('object_event_router_test.dart'));
      expect(stats.creationEvents, 1);
    });

    test('records nothing for LeakSentry\'s own objects', () {
      listen<_Widgety>((_) {});
      final own = _OwnWidgety();

      _dispatchCreated(own, className: '_OwnWidgety');

      expect(router.creationSites.take(own), isNull);
      expect(stats.creationEvents, 0);
    });

    test('records nothing for an object no handler cares about', () {
      listen<_Widgety>((_) {});
      final other = _Other();

      _dispatchCreated(other);

      expect(router.creationSites.take(other), isNull);
      expect(stats.creationEvents, 0);
    });

    test('records nothing when nothing is listening', () {
      final object = _Widgety();

      _dispatchCreated(object);

      expect(router.creationSites.take(object), isNull);
    });

    test('skips the framework objects Flutter creates thousands of times a second', () {
      listen<Object>((_) {});
      for (final className in ['Element', 'RenderObject', 'Layer', 'PipelineOwner', '_LocalSemanticsHandle']) {
        final object = _Widgety();
        _dispatchCreated(object, className: className);
        expect(router.creationSites.take(object), isNull, reason: className);
      }
      expect(stats.creationEvents, 0);
    });

    test('skips objects from dart:ui', () {
      listen<Object>((_) {});
      final object = _Widgety();

      _dispatchCreated(object, library: 'dart:ui');

      expect(router.creationSites.take(object), isNull);
    });

    test('the stack is handed over once, when the object is watched', () {
      listen<_Widgety>((_) {});
      final object = _createWidgety(router);

      expect(router.creationSites.take(object), isNotNull);
      expect(router.creationSites.take(object), isNull);
    });

    test('forgets creation stacks when the last handler goes away', () {
      final subscription = router.listenForDisposal<_Widgety>((_) {});
      final object = _createWidgety(router);
      expect(router.creationSites.length, 1);

      subscription.cancel();

      expect(router.creationSites.length, 0);
      expect(object, isNotNull);
    });

    test('prunes the stacks of objects that were collected without being disposed', () async {
      listen<_Widgety>((_) {});
      void createGarbage(int count) {
        for (var i = 0; i < count; i++) {
          _dispatchCreated(_Widgety());
        }
      }

      createGarbage(2000);
      expect(router.creationSites.length, 2000);
      await forceGc();
      createGarbage(100);

      // The 2048th creation pruned everything collected so far.
      expect(router.creationSites.length, lessThan(300));
    });
  });
}
