import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';
import 'package:leak_sentry/core/retain_instance_event.dart';
import 'package:leak_sentry/core/retained_notice.dart';
import 'package:leak_sentry/core/retained_object_notifier.dart';

import 'fakes/recording_notifier.dart';
import 'helpers/capture_log.dart';
import 'helpers/engine_fixture.dart';

class _Thing {}

class _ThrowingNotifier extends RecordingNotifier {
  @override
  void showRetainedCount({required int objectCount, required String contentText, RetainInstanceEvent? reason}) {
    super.showRetainedCount(objectCount: objectCount, contentText: contentText, reason: reason);
    throw StateError('cannot show');
  }
}

void main() {
  group('the notice controller', () {
    late RetainedNoticeController controller;
    late List<RetainedNotice?> seen;

    setUp(() {
      controller = RetainedNoticeController();
      seen = [];
      controller.addListener(() => seen.add(controller.value));
    });

    tearDown(() => controller.dispose());

    test('has nothing to say at first', () {
      expect(controller.value, isNull);
    });

    test('says how many objects are held, and why the heap is not dumped yet', () {
      controller.showRetainedCount(
        objectCount: 2,
        contentText: 'App visible, waiting until 5 retained objects',
        reason: const BelowThresholdEvent(2),
      );

      final notice = controller.value!;
      expect(notice.kind, RetainedNoticeKind.held);
      expect(notice.objectCount, 2);
      expect(notice.text, 'App visible, waiting until 5 retained objects');
      expect(notice.reason, isA<BelowThresholdEvent>().having((e) => e.retainedCount, 'retainedCount', 2));
    });

    test('a failed dump has a notice with no reason to wait', () {
      controller.showRetainedCount(objectCount: 5, contentText: 'Failed to dump heap');

      expect(controller.value!.kind, RetainedNoticeKind.held);
      expect(controller.value!.reason, isNull);
    });

    test('the trigger repeats itself every couple of seconds, and a repeat that changes nothing is not news', () {
      for (var i = 0; i < 3; i++) {
        controller.showRetainedCount(objectCount: 2, contentText: 'waiting', reason: const BelowThresholdEvent(2));
      }

      expect(seen, hasLength(1));
    });

    test('a changed count, text or reason is news', () {
      controller.showRetainedCount(objectCount: 2, contentText: 'waiting', reason: const BelowThresholdEvent(2));
      controller.showRetainedCount(objectCount: 3, contentText: 'waiting', reason: const BelowThresholdEvent(3));
      controller.showRetainedCount(objectCount: 3, contentText: 'waiting', reason: const DumpHappenedRecentlyEvent());
      controller.showRetainedCount(objectCount: 3, contentText: 'Heap dumping disabled', reason: const DumpingDisabledEvent('a'));
      controller.showRetainedCount(objectCount: 3, contentText: 'Heap dumping disabled', reason: const DumpingDisabledEvent('b'));

      expect(seen, hasLength(5));
    });

    test('says when every object was collected, and the notice goes with the retained count', () {
      controller.showNoMoreRetainedObjects();
      expect(controller.value!.kind, RetainedNoticeKind.allClear);

      controller.dismissRetainedCount();

      expect(controller.value, isNull);
    });

    test('dismissing the retained count removes a retained count', () {
      controller.showRetainedCount(objectCount: 2, contentText: 'waiting');

      controller.dismissRetainedCount();

      expect(controller.value, isNull);
    });

    test('says when a requested dump found nothing, and only its own dismissal removes that', () {
      controller.showNoRetainedObjectsOnRequest();
      expect(controller.value!.kind, RetainedNoticeKind.nothingOnRequest);

      controller.dismissRetainedCount();
      expect(controller.value, isNotNull, reason: 'the retained count is a different notice');

      controller.dismissNoRetainedObjectsOnRequest();
      expect(controller.value, isNull);
    });

    test('its own dismissal leaves a retained count alone', () {
      controller.showRetainedCount(objectCount: 2, contentText: 'waiting');

      controller.dismissNoRetainedObjectsOnRequest();

      expect(controller.value!.kind, RetainedNoticeKind.held);
    });

    test('dismissing when there is nothing to dismiss is quiet', () {
      controller.dismissRetainedCount();
      controller.dismissNoRetainedObjectsOnRequest();

      expect(seen, isEmpty);
    });

    test('a heap dump that was under way when it was disposed can still call it', () {
      controller.dispose();

      expect(
        () {
          controller.showRetainedCount(objectCount: 1, contentText: 'late');
          controller.showNoMoreRetainedObjects();
          controller.dismissRetainedCount();
          controller.showNoRetainedObjectsOnRequest();
          controller.dismissNoRetainedObjectsOnRequest();
        },
        returnsNormally,
      );
    });

    test('is disposed once, however many times', () {
      controller.dispose();

      expect(controller.dispose, returnsNormally);
    });
  });

  group('notices that are the same', () {
    test('have the same kind, count, text and reason', () {
      const a = RetainedNotice.held(objectCount: 2, text: 'waiting', reason: BelowThresholdEvent(2));
      const b = RetainedNotice.held(objectCount: 2, text: 'waiting', reason: BelowThresholdEvent(2));

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('are not the same when the reason counts something else, or is another reason', () {
      const base = RetainedNotice.held(objectCount: 2, text: 'waiting', reason: BelowThresholdEvent(2));

      expect(base, isNot(const RetainedNotice.held(objectCount: 2, text: 'waiting', reason: BelowThresholdEvent(3))));
      expect(base, isNot(const RetainedNotice.held(objectCount: 2, text: 'waiting', reason: DumpHappenedRecentlyEvent())));
      expect(base, isNot(const RetainedNotice.held(objectCount: 2, text: 'waiting')));
      expect(base, isNot(const RetainedNotice.held(objectCount: 3, text: 'waiting', reason: BelowThresholdEvent(2))));
      expect(base, isNot(const RetainedNotice.held(objectCount: 2, text: 'other', reason: BelowThresholdEvent(2))));
      expect(const RetainedNotice.allClear(), isNot(const RetainedNotice.nothingOnRequest()));
      expect(const RetainedNotice.allClear(), const RetainedNotice.allClear());
    });

    test('reasons of the same kind with nothing to compare are the same', () {
      const a = RetainedNotice.held(objectCount: 2, text: 'waiting', reason: DumpHappenedRecentlyEvent());
      const b = RetainedNotice.held(objectCount: 2, text: 'waiting', reason: DumpHappenedRecentlyEvent());

      expect(a, b);
    });
  });

  group('the composite notifier', () {
    test('passes every call to every notifier, in order', () {
      final first = RecordingNotifier();
      final second = RecordingNotifier();
      final composite = CompositeRetainedObjectNotifier([first, second]);

      composite.showRetainedCount(objectCount: 2, contentText: 'waiting', reason: const BelowThresholdEvent(2));
      composite.showNoMoreRetainedObjects();
      composite.dismissRetainedCount();
      composite.showNoRetainedObjectsOnRequest();
      composite.dismissNoRetainedObjectsOnRequest();

      const expected = ['retained(2, "waiting")', 'noMoreRetained', 'dismissRetained', 'noRetainedOnRequest', 'dismissNoRetainedOnRequest'];
      expect(first.calls, expected);
      expect(second.calls, expected);
      expect(first.reasons.single, isA<BelowThresholdEvent>());
    });

    test('one that throws does not keep the others from hearing the call, and the error still comes out', () {
      final throwing = _ThrowingNotifier();
      final after = RecordingNotifier();
      final composite = CompositeRetainedObjectNotifier([throwing, after]);

      expect(() => composite.showRetainedCount(objectCount: 1, contentText: 'x'), throwsStateError);

      expect(throwing.calls, hasLength(1));
      expect(after.calls, hasLength(1));
    });
  });

  group('the engine', () {
    late EngineFixture f;

    setUp(() {
      captureLog();
      f = EngineFixture();
      f.engine.install(watchers: const []);
    });

    tearDown(() => f.engine.dispose());

    test('has a notice controller of its own, next to the notifier it was given', () async {
      final things = [_Thing(), _Thing()];
      for (final thing in things) {
        f.engine.objectWatcher.watch(thing, 'why');
      }

      await f.time.elapse(const Duration(seconds: 5));

      final notice = f.engine.notices.value!;
      expect(notice.kind, RetainedNoticeKind.held);
      expect(notice.objectCount, 2);
      expect(notice.reason, isA<BelowThresholdEvent>());
      expect(f.notifier.calls, contains('retained(2, "App visible, waiting until 5 retained objects")'));
      expect(things, hasLength(2));
    });

    test('shows that dumping is switched off, when it is', () async {
      f.engine.dumpEnabledInAboutScreen = false;
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
      final thing = _Thing();
      f.engine.objectWatcher.watch(thing, 'why');

      await f.time.elapse(const Duration(seconds: 5));

      final notice = f.engine.notices.value!;
      expect(notice.reason, isA<DumpingDisabledEvent>());
      expect(f.notifier.reasons.last, isA<DumpingDisabledEvent>());
      expect(thing, isNotNull);
    });

    test('says nothing once the engine is disposed, even if a dump was still being sent', () async {
      f.engine.dispose();

      expect(() => f.engine.notices.showRetainedCount(objectCount: 1, contentText: 'late'), returnsNormally);
    });
  });
}
