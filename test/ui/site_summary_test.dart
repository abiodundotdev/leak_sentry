import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/site_summary.dart';

const _created = CreationSite(uri: 'package:app/page.dart', member: '_PageState.initState', line: 42, column: 11);
const _watched = CreationSite(uri: 'package:app/page.dart', member: '_PageState.build', line: 77);
const _declared = CreationSite(uri: 'package:app/page.dart', member: '_PageState', line: 12);

LeakInstance _instance({
  String signature = 's',
  int minute = 0,
  CreationSite? created,
  CreationSite? watched,
  CreationSite? declared,
}) => LeakInstance(
  signature: signature,
  leakedType: '_PageThreeState',
  count: 1,
  firstSeen: DateTime(2026, 1, 1, 12, minute),
  lastSeen: DateTime(2026, 1, 1, 12, minute),
  creationSite: created,
  watchSite: watched,
  classSite: declared,
);

LeakGroup _group(List<LeakInstance> instances, {LeakKind kind = LeakKind.retained}) => LeakGroup(
  id: 'g',
  kind: kind,
  leakedType: '_Page',
  reason: 'why',
  instances: instances,
  firstSeen: DateTime(2026),
  lastSeen: DateTime(2026),
  isUnread: false,
);

void main() {
  test('is a fallback when it is not where the object was created: where it was watched, or its class is declared', () {
    expect(summarizeSites(created: _created).isFallback, isFalse);
    expect(summarizeSites(created: _created, isResource: true).isFallback, isFalse, reason: 'where a resource was acquired is the real place');
    expect(summarizeSites(watched: _watched).isFallback, isTrue);
    expect(summarizeSites(declared: _declared).isFallback, isTrue);
    expect(summarizeSites().isFallback, isFalse, reason: 'nothing is known, which is not a place');
  });

  test('where it was created, with the member', () {
    final summary = summarizeSite(_group([_instance(created: _created)]));

    expect(summary.label, LeakSentryCopy.createdAt);
    expect(summary.text, 'lib/page.dart:42 · _PageState.initState');
    expect(summary.isMissing, isFalse);
    expect(summary.otherSites, 0);
  });

  test('a resource was acquired, not created', () {
    final summary = summarizeSite(_group([_instance(created: _created)], kind: LeakKind.resource));

    expect(summary.label, LeakSentryCopy.acquiredAt);
  });

  test('where it was handed to the watcher, when its creation is not known', () {
    final summary = summarizeSite(_group([_instance(watched: _watched)]));

    expect(summary.label, LeakSentryCopy.watchedAt);
    expect(summary.text, 'lib/page.dart:77 · _PageState.build');
  });

  test('where its class is declared, when nothing better is known', () {
    final summary = summarizeSite(_group([_instance(declared: _declared)]));

    expect(summary.label, LeakSentryCopy.classDeclaredAt);
    expect(summary.text, 'lib/page.dart:12 · _PageState');
    expect(summary.isMissing, isFalse);
  });

  test('the creation wins over the watcher, and the watcher over the class', () {
    expect(summarizeSite(_group([_instance(created: _created, watched: _watched, declared: _declared)])).label, LeakSentryCopy.createdAt);
    expect(summarizeSite(_group([_instance(watched: _watched, declared: _declared)])).label, LeakSentryCopy.watchedAt);
  });

  test('that it is not known, when it is not', () {
    final summary = summarizeSite(_group([_instance()]));

    expect(summary.label, LeakSentryCopy.creationUnknown);
    expect(summary.text, isEmpty);
    expect(summary.isMissing, isTrue);
  });

  test('a place with no member is just the file and line', () {
    final summary = summarizeSite(_group([_instance(created: const CreationSite(uri: 'package:app/p.dart', line: 3))]));

    expect(summary.text, 'lib/p.dart:3');
  });

  group('as a pin on a row', () {
    test('is the place, and under it the member', () {
      final parts = describePinParts(summarizeSite(_group([_instance(created: _created)])));

      expect(parts.place, 'lib/page.dart:42');
      expect(parts.member, '_PageState.initState');
    });

    test('says what kind of place it is, unless it is where the object was created', () {
      expect(describePinParts(summarizeSite(_group([_instance(watched: _watched)]))).place, 'watched at lib/page.dart:77');
      expect(describePinParts(summarizeSite(_group([_instance(declared: _declared)]))).place, 'class declared at lib/page.dart:12');
      expect(describePinParts(summarizeSite(_group([_instance(created: _created)], kind: LeakKind.resource))).place, 'acquired at lib/page.dart:42');
    });

    test('has no member when the place has none', () {
      final parts = describePinParts(summarizeSite(_group([_instance(created: const CreationSite(uri: 'package:app/p.dart', line: 3))])));

      expect(parts.place, 'lib/p.dart:3');
      expect(parts.member, isNull);
    });

    test('says there is none when there is none', () {
      final parts = describePinParts(summarizeSite(_group([_instance()])));

      expect(parts.place, LeakSentryCopy.creationUnknown);
      expect(parts.member, isNull);
    });

    test('says how many other places it came from, after the place', () {
      const other = CreationSite(uri: 'package:app/other.dart', member: 'make', line: 9);
      final summary = summarizeSite(_group([_instance(signature: 'a', minute: 5, created: other), _instance(signature: 'b', minute: 1, created: _created)]));

      expect(describePinParts(summary).place, 'lib/other.dart:9  +1 more');
      expect(describePinParts(summary).member, 'make');
    });
  });

  group('a leak that came from several places', () {
    const other = CreationSite(uri: 'package:app/other.dart', member: 'make', line: 9);

    test('shows where the latest came from, and how many other places there are', () {
      final summary = summarizeSite(
        _group([
          _instance(signature: 'old', minute: 1, created: _created),
          _instance(signature: 'new', minute: 5, created: other),
        ]),
      );

      expect(summary.text, 'lib/other.dart:9 · make');
      expect(summary.otherSites, 1);
    });

    test('counts a place once, however many instances came from it', () {
      final summary = summarizeSite(
        _group([
          _instance(signature: 'a', minute: 5, created: other),
          _instance(signature: 'b', minute: 1, created: _created),
          _instance(signature: 'c', minute: 2, created: _created),
          _instance(signature: 'd', minute: 3, created: other),
        ]),
      );

      expect(summary.text, 'lib/other.dart:9 · make');
      expect(summary.otherSites, 1);
    });

    test('does not count the place of the latest as another', () {
      final summary = summarizeSite(
        _group([_instance(signature: 'a', minute: 5, created: _created), _instance(signature: 'b', minute: 1, created: _created)]),
      );

      expect(summary.otherSites, 0);
    });
  });
}
