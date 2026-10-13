import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';
import 'package:leak_sentry/object_watcher/delayed_executor.dart';
import 'package:leak_sentry/object_watcher/object_watcher.dart';
import 'package:leak_sentry/utils/creation_site_util.dart';

import 'fakes/fake_time.dart';
import 'helpers/capture_log.dart';
import 'helpers/engine_fixture.dart';

class _Thing {}

const _delay = Duration(seconds: 5);

/// The line of this file that carries [marker] in a comment: the line a test expects a site to name.
int _lineOf(String marker) {
  final lines = File('test/watch_site_test.dart').readAsLinesSync();
  return lines.indexWhere((line) => line.endsWith('// $marker')) + 1;
}

void main() {
  group('the watcher remembers where an object was handed to it', () {
    late FakeTime time;
    late SchedulerDelayedExecutor executor;
    late bool enabled;
    late StackTrace? Function(Object) creationStackOf;
    late ObjectWatcher watcher;

    setUp(() {
      time = FakeTime();
      executor = SchedulerDelayedExecutor(scheduler: time, clock: time.clock);
      enabled = true;
      creationStackOf = (_) => null;
      watcher = ObjectWatcher(
        clock: time.clock,
        checkRetainedExecutor: (task) => executor.executeWithDelay(_delay, task),
        isEnabled: () => enabled,
        creationStackOf: (object) => creationStackOf(object),
      );
    });

    test('watch() records the line that called it', () {
      final thing = _Thing();
      watcher.watch(thing, 'why'); // watch-in-watcher-test
      time.advance(_delay);

      final snapshot = watcher.tracker.snapshotRetainedObjects().single;
      final site = CreationSiteUtil.resolve(snapshot.watchStack, type: _Thing);

      expect(site, isNotNull);
      expect(site!.uri, endsWith('watch_site_test.dart'));
      expect(site.line, _lineOf('watch-in-watcher-test'));
      expect(thing, isNotNull);
    });

    test('the frames of the watcher itself are not the site', () {
      final thing = _Thing();
      watcher.watch(thing, 'why');
      time.advance(_delay);

      final snapshot = watcher.tracker.snapshotRetainedObjects().single;

      expect(CreationSiteUtil.resolve(snapshot.watchStack, type: _Thing)!.uri, isNot(contains('object_watcher.dart')));
      expect(thing, isNotNull);
    });

    test('expectDeletionFor, which the default watchers use, records none: it has a creation stack instead', () {
      final thing = _Thing();
      watcher.expectDeletionFor(thing, 'why');
      time.advance(_delay);

      expect(watcher.tracker.snapshotRetainedObjects().single.watchStack, isNull);
      expect(thing, isNotNull);
    });

    test('a creation stack and the watch stack both travel with the object', () {
      final created = StackTrace.fromString('#0      _PageState.initState (package:app/page.dart:42:11)');
      creationStackOf = (_) => created;
      final thing = _Thing();
      watcher.watch(thing, 'why');
      time.advance(_delay);

      final snapshot = watcher.tracker.snapshotRetainedObjects().single;

      expect(snapshot.creationStack, same(created));
      expect(snapshot.watchStack, isNotNull);
      expect(thing, isNotNull);
    });

    test('a watcher that is turned off records nothing', () {
      enabled = false;
      final thing = _Thing();

      watcher.watch(thing, 'why');
      time.advance(_delay);

      expect(watcher.trackedObjectCount, 0);
      expect(watcher.tracker.snapshotRetainedObjects(), isEmpty);
      expect(thing, isNotNull);
    });
  });

  group('a leak of an object that was watched by hand', () {
    late EngineFixture f;

    setUp(() {
      captureLog();
      f = EngineFixture();
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
      f.engine.install(watchers: const []);
    });

    tearDown(() => f.engine.dispose());

    test('says where it was handed over, when Flutter never saw it created', () async {
      final thing = _Thing();
      f.engine.objectWatcher.watch(thing, 'a manually watched thing'); // watch-in-engine-test
      await f.time.elapse(_delay);

      final report = f.engine.hub.leakHistory.single;

      expect(report.creationSite, isNull);
      expect(report.watchSite, isNotNull);
      expect(report.watchSite!.uri, endsWith('watch_site_test.dart'));
      expect(report.watchSite!.line, _lineOf('watch-in-engine-test'));
      expect(report.creationSiteGap, isNull);
      expect(report.toString(), contains('watchedAt: '));
      expect(thing, isNotNull);
    });
  });
}
