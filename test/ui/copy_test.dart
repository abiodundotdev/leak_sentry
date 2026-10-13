import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/ui/copy.dart';

/// The text between the quotes of every string literal in a Dart file.
Iterable<String> _literals(String source) sync* {
  final pattern = RegExp(r"'((?:[^'\\\n]|\\.)*)'|" r'"((?:[^"\\\n]|\\.)*)"');
  for (final match in pattern.allMatches(source)) {
    yield match.group(1) ?? match.group(2) ?? '';
  }
}

void main() {
  group('the wording is LeakSentry\'s own', () {
    // Phrases the screens must not use. A phrase that is only one common word is matched as a whole word.
    final banned = <String, RegExp>{
      for (final phrase in [
        'distinct leaks', 'leaks at', 'last leaked', 'heap dump', 'dump heap now', 'dump heap automatically',
        'library leak', 'verdict', 'gc root', 'tap here to learn more', 'delete all', 'share heap dump',
        'references underlined', 'leaking:', 'is expected', 'is stuck', 'retained objects',
        'all retained objects were garbage collected', 'tap to dismiss', 'failed to dump heap',
        'less than a minute ago', 'grouped as',
      ])
        phrase: RegExp(RegExp.escape(phrase), caseSensitive: false),
      'import': RegExp(r'\bimport\b', caseSensitive: false),
      'about': RegExp(r'\babout\b', caseSensitive: false),
    };

    final files = [
      for (final entity in Directory('lib/ui').listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart')) entity,
    ];

    test('there are files to check', () {
      expect(files, isNotEmpty);
      expect(files.map((file) => file.path), contains('lib/ui/copy.dart'));
    });

    for (final file in files) {
      test('no string in ${file.path} uses a phrase the screens must not use', () {
        for (final literal in _literals(file.readAsStringSync())) {
          for (final phrase in banned.entries) {
            expect(phrase.value.hasMatch(literal), isFalse, reason: '"$literal" says "${phrase.key}"');
          }
        }
      });
    }

    test('and the scan catches what it is looking for', () {
      expect(_literals("const a = 'Last leaked 5 minutes ago';").single, 'Last leaked 5 minutes ago');
      expect(banned['last leaked']!.hasMatch('Last leaked 5 minutes ago'), isTrue);
      expect(banned['about']!.hasMatch('About'), isTrue);
      expect(banned['about']!.hasMatch('Sabout'), isFalse);
    });
  });

  group('plural forms', () {
    test('count what they say they count', () {
      expect(LeakSentryCopy.leaksSummary(4, 11), '4 leaks spotted · 11 objects');
      expect(LeakSentryCopy.leaksSummary(1, 1), '1 leak spotted · 1 object');
      expect(LeakSentryCopy.badgeLeaks(1), '1 leak');
      expect(LeakSentryCopy.badgeLeaks(3), '3 leaks');
      expect(LeakSentryCopy.instances(1), '1 instance');
      expect(LeakSentryCopy.instances(3), '3 instances');
      expect(LeakSentryCopy.moreSteps(1), '1 more step to the root');
      expect(LeakSentryCopy.moreSteps(52), '52 more steps to the root');
    });

    test('a scan says how many objects were held, and what it found', () {
      expect(LeakSentryCopy.scanSummary(5, 2, 1), '5 held · 2 leaks (1 new)');
      expect(LeakSentryCopy.scanSummary(5, 1, 0), '5 held · 1 leak');
      expect(LeakSentryCopy.scanSummary(3, 0, 0), '3 held · no leaks');
    });

    test('the badge notice says how many are held and what is next', () {
      expect(LeakSentryCopy.noticeHeld(3, 5), '3 held · scans at 5');
      expect(LeakSentryCopy.noticeRecent(5), '5 held · scanned moments ago');
      expect(LeakSentryCopy.noticeSwitchedOff(2), '2 held · scanning is off');
      expect(LeakSentryCopy.noticeFailed(5), '5 held · last scan failed');
    });
  });

  group('every reason has a sentence', () {
    test('for a missing creation site', () {
      final sentences = [for (final gap in CreationSiteGap.values) LeakSentryCopy.creationGap(gap)];

      expect(sentences, everyElement(isNotEmpty));
      expect(sentences.toSet(), hasLength(CreationSiteGap.values.length), reason: 'no two reasons read the same');
    });

    test('for a missing path', () {
      final sentences = [for (final gap in RetainingPathGap.values) LeakSentryCopy.pathGap(gap)];

      expect(sentences, everyElement(isNotEmpty));
      expect(sentences.toSet(), hasLength(RetainingPathGap.values.length));
    });

    test('the State that has no initState is named, because it is the case a developer meets', () {
      expect(LeakSentryCopy.creationGap(CreationSiteGap.onlyFrameworkFrames), contains('initState'));
    });

    test('each creation reason says its own reason', () {
      const expected = {
        CreationSiteGap.notDebugBuild: 'debug builds',
        CreationSiteGap.web: 'web',
        CreationSiteGap.notAnnounced: 'never reported',
        CreationSiteGap.onlyFrameworkFrames: 'None of your code',
        CreationSiteGap.symbolless: '--split-debug-info',
        CreationSiteGap.unparseable: 'could not be read',
      };

      expect(expected.keys, unorderedEquals(CreationSiteGap.values));
      for (final reason in expected.entries) {
        expect(LeakSentryCopy.creationGap(reason.key), contains(reason.value), reason: '${reason.key}');
      }
    });

    test('each path reason says its own reason', () {
      const expected = {
        RetainingPathGap.disabled: 'turned off',
        RetainingPathGap.noVmService: 'no VM service',
        RetainingPathGap.lookupLimitReached: 'as many paths',
        RetainingPathGap.objectUnavailable: 'no handle',
        RetainingPathGap.lookupFailed: 'could not be reached',
      };

      expect(expected.keys, unorderedEquals(RetainingPathGap.values));
      for (final reason in expected.entries) {
        expect(LeakSentryCopy.pathGap(reason.key), contains(reason.value), reason: '${reason.key}');
      }
    });
  });

  group('what a path starts at', () {
    test('is put in plain words', () {
      expect(LeakSentryCopy.startsAt('user global'), 'Starts at: a static variable');
      expect(LeakSentryCopy.startsAt('class table'), 'Starts at: a class');
      expect(LeakSentryCopy.startsAt('stack'), 'Starts at: a running function');
      expect(LeakSentryCopy.startsAt('persistent handle'), 'Starts at: a native handle');
    });

    test('is still something when the VM names a root this does not know', () {
      expect(LeakSentryCopy.startsAt('something new'), 'Starts at: something the app keeps alive');
    });
  });
}
