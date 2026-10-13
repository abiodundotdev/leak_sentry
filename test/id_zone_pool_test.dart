import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/utils/id_zone_pool.dart';

void main() {
  late List<String> events;
  late int made;
  late bool vmHasZones;
  Object? emptyError;
  late IdZonePool pool;

  setUp(() {
    events = [];
    made = 0;
    vmHasZones = true;
    emptyError = null;
    pool = IdZonePool(
      create: (isolateId) async {
        if (!vmHasZones) return null;
        final zone = 'zones/${++made}';
        events.add('create $zone in $isolateId');
        return zone;
      },
      empty: (isolateId, zoneId) async {
        events.add('empty $zoneId in $isolateId');
        final error = emptyError;
        if (error != null) throw error;
      },
    );
  });

  group('a zone', () {
    test('is made when none is waiting', () async {
      expect(await pool.acquire('isolates/1'), 'zones/1');
      expect(events, ['create zones/1 in isolates/1']);
    });

    test('is emptied when it is given back, and handed out again to the next lookup', () async {
      final zone = (await pool.acquire('isolates/1'))!;
      await pool.release('isolates/1', zone);

      expect(await pool.acquire('isolates/1'), zone);
      expect(events, ['create zones/1 in isolates/1', 'empty zones/1 in isolates/1']);
    });

    test('is reused by every lookup that follows: a scan after a scan makes no zone', () async {
      for (var scan = 0; scan < 5; scan++) {
        final first = (await pool.acquire('isolates/1'))!;
        final second = (await pool.acquire('isolates/1'))!;
        await pool.release('isolates/1', first);
        await pool.release('isolates/1', second);
      }

      expect(made, 2, reason: 'two lookups at a time need two zones, and no more were ever made');
    });

    test('goes to one lookup at a time, also when lookups ask at the same moment', () async {
      final first = (await pool.acquire('isolates/1'))!;
      final second = (await pool.acquire('isolates/1'))!;
      await pool.release('isolates/1', first);
      await pool.release('isolates/1', second);

      final zones = await Future.wait([pool.acquire('isolates/1'), pool.acquire('isolates/1'), pool.acquire('isolates/1')]);

      expect(zones.toSet(), hasLength(3), reason: 'two waiting zones, and a new one for the third');
      expect(made, 3);
    });

    test('is not handed out again before it is given back', () async {
      final first = await pool.acquire('isolates/1');
      final second = await pool.acquire('isolates/1');

      expect(second, isNot(first));
    });

    test('is not kept when it cannot be emptied: it may still hold objects', () async {
      final zone = (await pool.acquire('isolates/1'))!;
      emptyError = StateError('the VM service went away');

      await expectLater(pool.release('isolates/1', zone), throwsStateError);
      emptyError = null;

      expect(await pool.acquire('isolates/1'), isNot(zone));
    });

    test('is kept once when it is given back twice', () async {
      final zone = (await pool.acquire('isolates/1'))!;
      await pool.release('isolates/1', zone);
      await pool.release('isolates/1', zone);

      final first = await pool.acquire('isolates/1');
      final second = await pool.acquire('isolates/1');

      expect(first, zone);
      expect(second, isNot(zone), reason: 'two lookups must not end up in one zone');
    });

    test('belongs to the isolate it was made in', () async {
      final zone = (await pool.acquire('isolates/1'))!;
      await pool.release('isolates/1', zone);

      expect(await pool.acquire('isolates/2'), isNot(zone));
      expect(await pool.acquire('isolates/1'), zone);
    });

    test('is null when the VM has none to give, and nothing is kept', () async {
      vmHasZones = false;

      expect(await pool.acquire('isolates/1'), isNull);
      expect(events, isEmpty);
    });

    test('is not made when making one fails: the error is the caller\'s', () async {
      final failing = IdZonePool(create: (isolateId) => throw StateError('no zones'), empty: (isolateId, zoneId) async {});

      await expectLater(failing.acquire('isolates/1'), throwsStateError);
    });
  });

  group('the VM\'s zones', () {
    // In Dart 3.6 to 3.10 (Flutter 3.27 to 3.38) a deleted zone leaves a hole in the VM's list of zones that
    // its garbage collector walks into at the next run: the app dies with a segmentation fault.
    test('are never deleted: nothing under lib/ asks the VM to', () {
      final offenders = [
        for (final entity in Directory('lib').listSync(recursive: true))
          if (entity is File && entity.path.endsWith('.dart') && entity.readAsStringSync().contains('deleteIdZone')) entity.path,
      ];

      expect(offenders, isEmpty, reason: 'delete a zone and the Dart VM of Flutter 3.27 to 3.38 crashes at its next GC: empty it instead');
    });
  });
}
