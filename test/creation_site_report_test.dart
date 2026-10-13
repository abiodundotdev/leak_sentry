import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/object_watcher/default_watchers.dart';

import 'helpers/capture_log.dart';
import 'helpers/engine_fixture.dart';

class _Notifier {}

// Two separate "places in application code" that create a _Notifier. Each
// dispatches the creation event itself (rather than through a shared
// helper) so that each has its own line for the report to point at.
_Notifier _createdHere() {
  final notifier = _Notifier();
  FlutterMemoryAllocations.instance.dispatchObjectEvent(
    ObjectCreated(library: 'package:flutter/foundation.dart', className: 'ChangeNotifier', object: notifier),
  );
  return notifier;
}

_Notifier _createdThere() {
  final notifier = _Notifier();
  FlutterMemoryAllocations.instance.dispatchObjectEvent(
    ObjectCreated(library: 'package:flutter/foundation.dart', className: 'ChangeNotifier', object: notifier),
  );
  return notifier;
}

void _dispose(Object object) =>
    FlutterMemoryAllocations.instance.dispatchObjectEvent(ObjectDisposed(object: object));

void main() {
  late EngineFixture f;

  setUp(() {
    captureLog();
    f = EngineFixture();
    f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
    f.engine.install(watchers: [AllDisposedObjectsWatcher(f.engine.objectWatcher, router: f.router)]);
  });

  tearDown(() => f.engine.dispose());

  Future<void> leakAndDump() => f.time.elapse(const Duration(seconds: 5));

  test('a leaked object\'s report says where it was created', () async {
    final leaked = _createdHere();
    _dispose(leaked);

    await leakAndDump();

    final report = f.engine.hub.leakHistory.single;
    expect(report.creationSite?.member, '_createdHere');
    expect(report.creationSite?.uri, endsWith('creation_site_report_test.dart'));
    expect(report.toString(), contains('createdAt: _createdHere'));
    expect(leaked, isNotNull); // keeps the object reachable until the leak is reported
  });

  test('an object that was never seen being created is still reported, without a creation site', () async {
    final leaked = _Notifier();
    _dispose(leaked);

    await leakAndDump();

    final report = f.engine.hub.leakHistory.single;
    expect(report.creationSite, isNull);
    expect(report.creationSiteGap, CreationSiteGap.notAnnounced, reason: 'a report says why it has no creation site');
    expect(report.toString(), contains('creation site unavailable (notAnnounced)'));
    expect(leaked, isNotNull);
  });

  test('a leaked object whose creation was seen has no reason to give', () async {
    final leaked = _createdHere();
    _dispose(leaked);

    await leakAndDump();

    expect(f.engine.hub.leakHistory.single.creationSiteGap, isNull);
    expect(leaked, isNotNull);
  });

  test('leaks of one type created at different places are reported separately', () async {
    final first = _createdHere();
    final second = _createdThere();
    _dispose(first);
    _dispose(second);

    await leakAndDump();

    final history = f.engine.hub.leakHistory;
    expect(history, hasLength(2));
    expect(history.map((report) => report.creationSite?.member), unorderedEquals(['_createdHere', '_createdThere']));
    expect([first, second], hasLength(2));
  });

  test('leaks of one type created at the same place dedupe into one report', () async {
    final first = _createdHere();
    final second = _createdHere();
    _dispose(first);
    _dispose(second);

    await leakAndDump();

    expect(f.engine.hub.leakHistory, hasLength(1));
    expect(f.engine.hub.leakHistory.single.occurrenceCount, 2);
    expect([first, second], hasLength(2));
  });
}
