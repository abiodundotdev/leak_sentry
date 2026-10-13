import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';

import 'helpers/capture_log.dart';
import 'helpers/engine_fixture.dart';
import 'helpers/force_gc.dart';

class _Thing {}

void main() {
  setUp(captureLog);

  test('the screens\' view of a leak does not keep the leaked object alive', () async {
    final f = EngineFixture();
    addTearDown(f.engine.dispose);
    f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
    f.engine.install(watchers: const []);

    // What a real leak looks like: something holds the object, so it is retained.
    final holder = <_Thing>[];
    late final WeakReference<_Thing> reference;
    void leak() {
      final thing = _Thing();
      holder.add(thing);
      reference = WeakReference(thing);
      f.engine.objectWatcher.watch(thing, 'a thing was disposed');
    }

    leak();
    await f.time.elapse(const Duration(seconds: 5));

    // The engine found it, and the catalog, the hub and every event hold what it found.
    expect(f.engine.catalog.groups, hasLength(1));
    expect(f.engine.hub.leakHistory, hasLength(1));
    expect(f.events, isNotEmpty);
    await forceGc();
    expect(reference.target, isNotNull, reason: 'it is still held by the leak, as it should be');

    // The leak is fixed: whatever held the object lets go. Nothing LeakSentry
    // remembers may be what keeps it.
    holder.clear();
    await forceGc();

    expect(reference.target, isNull, reason: 'the engine, the catalog, the hub or an event still refers to the object');
    expect(f.engine.catalog.groups, hasLength(1), reason: 'and the leak is still listed, because it keeps names, not the object');
  });
}
