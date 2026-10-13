import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/ui/format.dart';

void main() {
  final now = DateTime(2026, 10, 12, 12);

  String ago(Duration elapsed) => formatAgo(now.subtract(elapsed), now);

  group('how long ago', () {
    test('a moment ago is just now, up to 45 seconds', () {
      expect(ago(Duration.zero), 'just now');
      expect(ago(const Duration(seconds: 44)), 'just now');
    });

    test('then it is minutes, at least one', () {
      expect(ago(const Duration(seconds: 45)), '1 min ago');
      expect(ago(const Duration(seconds: 119)), '1 min ago');
      expect(ago(const Duration(minutes: 2)), '2 min ago');
      expect(ago(const Duration(minutes: 11)), '11 min ago');
      expect(ago(const Duration(minutes: 59, seconds: 59)), '59 min ago');
    });

    test('then hours', () {
      expect(ago(const Duration(hours: 1)), '1 h ago');
      expect(ago(const Duration(hours: 5, minutes: 40)), '5 h ago');
      expect(ago(const Duration(hours: 23, minutes: 59)), '23 h ago');
    });

    test('then yesterday, for the next day', () {
      expect(ago(const Duration(days: 1)), 'yesterday');
      expect(ago(const Duration(days: 1, hours: 23)), 'yesterday');
    });

    test('then days, for a month', () {
      expect(ago(const Duration(days: 2)), '2 days ago');
      expect(ago(const Duration(days: 29)), '29 days ago');
      expect(ago(const Duration(days: 29, hours: 23)), '29 days ago');
    });

    test('and from the thirtieth day on, the date', () {
      expect(ago(const Duration(days: 30)), 'Sep 12');
    });

    test('then the date, with the year only when it is another year', () {
      expect(formatAgo(DateTime(2026, 8, 3), now), 'Aug 3');
      expect(formatAgo(DateTime(2025, 12, 31), now), 'Dec 31, 2025');
    });

    test('a time in the future, because a clock moved, is just now', () {
      expect(formatAgo(now.add(const Duration(minutes: 5)), now), 'just now');
    });
  });

  group('how long something took', () {
    test('is milliseconds, then seconds', () {
      expect(formatDuration(const Duration(milliseconds: 30)), '30 ms');
      expect(formatDuration(const Duration(milliseconds: 999)), '999 ms');
      expect(formatDuration(const Duration(milliseconds: 1000)), '1.0 s');
      expect(formatDuration(const Duration(milliseconds: 1449)), '1.4 s');
    });
  });

  group('a place in the source', () {
    const site = CreationSite(uri: 'package:leak_entry_app/main.dart', member: '_PageThreeState.initState', line: 196, column: 11);

    test('is a file and a line on a row', () {
      expect(shortLocation(site), 'lib/main.dart:196');
    });

    test('is the whole location to copy', () {
      expect(fullLocation(site), 'package:leak_entry_app/main.dart:196:11');
    });

    test('has its package apart, to show dim', () {
      expect(locationPackage(site), 'package:leak_entry_app');
    });

    test('without a line is just the file', () {
      const bare = CreationSite(uri: 'package:app/page.dart');

      expect(shortLocation(bare), 'lib/page.dart');
      expect(fullLocation(bare), 'package:app/page.dart');
    });

    test('without a column is a file and a line', () {
      const noColumn = CreationSite(uri: 'package:app/page.dart', line: 7);

      expect(fullLocation(noColumn), 'package:app/page.dart:7');
    });

    test('in a file path, not a package, is its folder and its name', () {
      const file = CreationSite(uri: 'file:///Users/dev/app/lib/page.dart', line: 3);

      expect(shortLocation(file), 'lib/page.dart:3');
      expect(locationPackage(file), 'file:///Users/dev/app/lib');
    });

    test('in a folder of the package has the folder, which tells files of one name apart', () {
      expect(shortLocation(const CreationSite(uri: 'package:app/screens/home/page.dart', line: 42)), 'home/page.dart:42');
      expect(shortLocation(const CreationSite(uri: 'package:app/screens/page.dart', line: 42)), 'screens/page.dart:42');
      expect(shortLocation(const CreationSite(uri: 'package:app/page.dart', line: 42)), 'lib/page.dart:42');
    });

    test('does not show what follows a ? in the address', () {
      expect(shortLocation(const CreationSite(uri: 'package:app/page.dart?x=1', line: 4)), 'lib/page.dart:4');
    });

    test('of a library with no path is the library', () {
      expect(shortLocation(const CreationSite(uri: 'dart:async', line: 4)), 'dart:async:4');
      expect(shortLocation(const CreationSite(uri: 'package:app')), 'package:app');
    });

    test('with nothing before the file name has no package', () {
      expect(locationPackage(const CreationSite(uri: 'page.dart')), '');
      expect(shortLocation(const CreationSite(uri: 'page.dart', line: 1)), 'page.dart:1');
    });
  });

  group('text that may break the line', () {
    const zwsp = '\u200B';

    test('can break after each of the characters it is told to, where a word follows', () {
      expect(breakable('_CustomZone.bindUnaryCallback.<anonymous closure>', after: '.'), '_CustomZone.${zwsp}bindUnaryCallback.$zwsp<anonymous\u00A0closure>');
      expect(breakable('package:leak_entry_app/main.dart', after: '/:'), 'package:${zwsp}leak_entry_app/${zwsp}main.dart');
    });

    test('keeps an anonymous closure in one piece, wherever the line breaks', () {
      expect(breakable('<anonymous closure>', after: '.'), '<anonymous\u00A0closure>');
      expect(breakable('a.<anonymous closure>.b', after: '.').contains(' '), isFalse);
    });

    test('leaves it alone when there is nowhere to break', () {
      expect(breakable('_PageSixState', after: '.'), '_PageSixState');
      expect(breakable('', after: '.'), '');
    });

    test('does not break at the end, before a space, or between two of them', () {
      expect(breakable('end.', after: '.'), 'end.');
      expect(breakable('a. b', after: '.'), 'a. b');
      expect(breakable('a..b', after: '.'), 'a..${zwsp}b');
    });

    test('only breaks after what it is told to', () {
      expect(breakable('a.b/c', after: '.'), 'a.${zwsp}b/c');
      expect(breakable('a.b/c', after: '/'), 'a.b/${zwsp}c');
    });

    test('never changes what the text says: take the breaks out and it is the text', () {
      const text = 'dart:isolate-patch/timer_impl.dart:3.<anonymous closure>';

      expect(breakable(text, after: './:').replaceAll(zwsp, '').replaceAll('\u00A0', ' '), text);
    });
  });

  group('a count and its noun', () {
    test('is singular for one and plural otherwise', () {
      expect(countOf(1, 'object'), '1 object');
      expect(countOf(0, 'object'), '0 objects');
      expect(countOf(2, 'object'), '2 objects');
    });

    test('takes a plural that is not the noun and an s', () {
      expect(countOf(1, 'entry', 'entries'), '1 entry');
      expect(countOf(2, 'entry', 'entries'), '2 entries');
    });
  });

  group('a phrase with an "and"', () {
    test('is kept from ending a line on the "and": the next word is held to it', () {
      expect(glueAnd('A and B'), 'A and\u00A0B');
      expect(glueAnd('A, B and 2 more'), 'A, B and\u00A02 more');
    });

    test('is left alone when it has none', () {
      expect(glueAnd('A, B'), 'A, B');
      expect(glueAnd('brand new'), 'brand new', reason: 'an "and" inside a word is not one');
    });
  });

  group('a list of types', () {
    test('is told as a phrase', () {
      expect(describeTypes([]), '');
      expect(describeTypes(['A']), 'A');
      expect(describeTypes(['A', 'B']), 'A and B');
      expect(describeTypes(['A', 'B', 'C']), 'A, B and 1 more');
      expect(describeTypes(['A', 'B', 'C', 'D', 'E']), 'A, B and 3 more');
    });
  });
}
