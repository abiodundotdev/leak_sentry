import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/leak_sentry_tab.dart';
import 'package:leak_sentry/models/leak_sentry_internal.dart';
import 'package:leak_sentry/object_watcher/default_watchers.dart';
import 'package:leak_sentry/object_watcher/deletable_object_reporter.dart';
import 'package:leak_sentry/ui/leak_sentry_route.dart';
import 'package:leak_sentry/ui/leak_sentry_screen.dart';

import 'helpers/capture_log.dart';
import 'helpers/engine_fixture.dart';
import 'helpers/leak_events.dart';

/// Remembers what it was asked to expect the deletion of.
class _Reporter implements DeletableObjectReporter {
  final List<Object> targets = [];

  @override
  TrackedObjectReachability expectDeletionFor(Object target, String reason) {
    targets.add(target);
    return const UntrackedObjectReachability();
  }
}

void main() {
  group('LeakSentry\'s own objects are never watched', () {
    test('every State, route and notifier declared in the package says it is LeakSentry\'s', () {
      // The kinds of object the default watchers watch: a State, a Route, a
      // ChangeNotifier (a ValueNotifier is one), an AnimationController.
      final declaration = RegExp(
        r'class\s+(\w+)(?:<[^{]*?>)?\s+extends\s+(State|ChangeNotifier|ValueNotifier|AnimationController|MaterialPageRoute|PageRoute|Route|PopupRoute|ModalRoute)\b[^{]*\{',
      );
      final files = [
        for (final entity in Directory('lib').listSync(recursive: true))
          if (entity is File && entity.path.endsWith('.dart')) entity,
      ];
      final checked = <String>[];

      for (final file in files) {
        for (final match in declaration.allMatches(file.readAsStringSync())) {
          final header = match.group(0)!;
          checked.add('${file.path}: ${match.group(1)}');
          expect(header, contains('LeakSentryInternal'), reason: '${match.group(1)} in ${file.path} would be watched for leaks');
        }
      }

      expect(checked, isNotEmpty, reason: 'the scan finds the declarations it is looking for');
      expect(checked.where((name) => name.contains('leak_sentry_screen.dart')), isNotEmpty);
      expect(checked.where((name) => name.contains('leak_sentry_overlay.dart')), isNotEmpty);
    });

    test('and the scan finds one that does not', () {
      final declaration = RegExp(r'class\s+(\w+)(?:<[^{]*?>)?\s+extends\s+(State)\b[^{]*\{');

      expect(declaration.firstMatch('class _S extends State<W> {}')!.group(0), isNot(contains('LeakSentryInternal')));
      expect(declaration.firstMatch('class _S extends State<W> implements LeakSentryInternal {}')!.group(0), contains('LeakSentryInternal'));
    });

    testWidgets('the engine\'s catalog, notices and screen flag are marked', (tester) async {
      captureLog();
      final f = EngineFixture();
      addTearDown(f.engine.dispose);

      expect(f.engine.catalog, isA<LeakSentryInternal>());
      expect(f.engine.notices, isA<LeakSentryInternal>());
      expect(f.engine.screenOpen, isA<LeakSentryInternal>());
    });

    testWidgets('the screen, its state and its route are marked', (tester) async {
      captureLog();
      final f = EngineFixture();
      addTearDown(f.engine.dispose);
      late NavigatorState navigator;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
        navigator = Navigator.of(context);
        return const SizedBox();
      })));
      final route = LeakSentryRoute<void>(engine: f.engine, builder: (_) => LeakSentryScreen.withEngine(engine: f.engine));

      navigator.push(route);
      await tester.pumpAndSettle();

      expect(route, isA<LeakSentryInternal>());
      expect(tester.state(find.byType(LeakSentryScreen)), isA<LeakSentryInternal>());
    });

    testWidgets('and while the screen opens, works and closes, the watchers are never given one of them', (tester) async {
      captureLog();
      final f = EngineFixture();
      addTearDown(f.engine.dispose);
      final reporter = _Reporter();
      final watchers = [
        StateWatcher(reporter, router: f.router),
        RouteWatcher(reporter, router: f.router),
        ChangeNotifierWatcher(reporter, router: f.router),
        AnimationControllerWatcher(reporter, router: f.router),
      ];
      for (final watcher in watchers) {
        watcher.install();
      }
      addTearDown(() {
        for (final watcher in watchers) {
          watcher.uninstall();
        }
      });
      runScan(f.engine.catalog, 'a', [leakReport()]);
      late NavigatorState navigator;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
        navigator = Navigator.of(context);
        return const SizedBox();
      })));

      navigator.push(
        LeakSentryRoute<void>(engine: f.engine, builder: (_) => LeakSentryScreen.withEngine(engine: f.engine, initialTab: LeakSentryTab.leaks)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('PageThreeState'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      expect(reporter.targets, isNotEmpty, reason: 'Flutter\'s own States were disposed, and are watched');
      expect(reporter.targets.whereType<LeakSentryInternal>(), isEmpty);
      expect(reporter.targets.map((target) => target.runtimeType.toString()), isNot(contains('_LeakSentryScreenState')));
    });
  });
}
