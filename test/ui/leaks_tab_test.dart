import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/leak_sentry_tab.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/format.dart';
import 'package:leak_sentry/ui/tokens.dart';
import 'package:leak_sentry/ui/widgets/leak_card.dart';

import '../helpers/capture_log.dart';
import '../helpers/engine_fixture.dart';
import '../helpers/leak_events.dart';
import '../helpers/pump_ui.dart';

const _watched = CreationSite(uri: 'package:leak_entry_app/main.dart', member: 'build', line: 77, column: 5);
const _declared = CreationSite(uri: 'package:leak_entry_app/main.dart', member: '_NoInitState', line: 12, column: 1);

void main() {
  late EngineFixture f;

  setUp(() {
    captureLog();
    f = EngineFixture();
  });

  tearDown(() => f.engine.dispose());

  group('with no leaks', () {
    testWidgets('says so', (tester) async {
      await pumpScreen(tester, f);

      expect(find.text(LeakSentryCopy.leaksEmptyTitle), findsOneWidget);
      expect(find.text(LeakSentryCopy.leaksEmptyBody), findsOneWidget);
      expect(find.byType(LeakCard), findsNothing);
    });

    testWidgets('has three tabs, and the Leaks tab is the one showing', (tester) async {
      await pumpScreen(tester, f);

      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('Leaks')), findsOneWidget);
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('Scans')), findsOneWidget);
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('Settings')), findsOneWidget);
      expect(find.descendant(of: find.byType(AppBar), matching: find.text('Leaks')), findsOneWidget);
    });
  });

  group('with leaks', () {
    testWidgets('lists each leak with how many objects it holds', (tester) async {
      runScan(f.engine.catalog, 'a', [
        leakReport(type: PageThreeState, count: 4, signature: 'three'),
        leakReport(type: PageFourState, count: 1, signature: 'four', created: const CreationSite(uri: 'package:leak_entry_app/main.dart', member: '_PageFourState.initState', line: 251, column: 5)),
      ]);

      await pumpScreen(tester, f);

      expect(find.byType(LeakCard), findsNWidgets(2));
      expect(find.text(LeakSentryCopy.leaksSummary(2, 5)), findsOneWidget);
      expect(find.text('PageThreeState'), findsOneWidget);
      expect(find.text('PageFourState'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
    });

    testWidgets('lists the one with the most objects first', (tester) async {
      runScan(f.engine.catalog, 'a', [
        leakReport(type: PageFourState, count: 1, signature: 'four'),
        leakReport(type: PageThreeState, count: 4, signature: 'three'),
      ]);

      await pumpScreen(tester, f);

      expect(tester.getTopLeft(find.text('PageThreeState')).dy, lessThan(tester.getTopLeft(find.text('PageFourState')).dy));
    });

    testWidgets('every one says where its object was created, as file and line', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);

      await pumpScreen(tester, f);

      expect(find.text('lib/main.dart:196'), findsOneWidget);
      expect(find.text(breakable('_PageThreeState.initState', after: '.')), findsOneWidget);
    });

    testWidgets('and says so even for a leak that has no creation site, and why it helps to look at the detail', (tester) async {
      runScan(f.engine.catalog, 'a', [
        leakReport(type: PageThreeState, signature: 'created'),
        leakReport(type: PageFourState, signature: 'watched', created: null, watched: _watched),
        leakReport(type: AppSettings, signature: 'declared', created: null, gap: CreationSiteGap.onlyFrameworkFrames, declared: _declared),
        leakReport(type: LeakyOther, signature: 'nothing', created: null, gap: CreationSiteGap.notAnnounced),
      ]);

      await pumpScreen(tester, f);

      expect(find.text('lib/main.dart:196'), findsOneWidget);
      expect(find.text(breakable('_PageThreeState.initState', after: '.')), findsOneWidget);
      expect(find.text('watched at lib/main.dart:77'), findsOneWidget);
      expect(find.text('build'), findsOneWidget);
      expect(find.text('class declared at lib/main.dart:12'), findsOneWidget);
      expect(find.text('_NoInitState'), findsOneWidget);
      expect(find.text(LeakSentryCopy.creationUnknown), findsOneWidget);
    });

    testWidgets('a new leak is marked NEW, and says when it was seen', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);

      await pumpScreen(tester, f);

      expect(find.text('NEW'), findsOneWidget);
      expect(find.text('seen just now'), findsOneWidget);
    });

    testWidgets('the time moves on while the screen is open', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await pumpScreen(tester, f);
      expect(find.text('seen just now'), findsOneWidget);

      f.time.advance(const Duration(minutes: 3, seconds: 5));
      await tester.pump();

      expect(find.text('seen 3 min ago'), findsOneWidget);
    });

    testWidgets('a leak found while the screen is open appears in it', (tester) async {
      await pumpScreen(tester, f);
      expect(find.byType(LeakCard), findsNothing);

      runScan(f.engine.catalog, 'a', [leakReport()]);
      await tester.pump();

      expect(find.byType(LeakCard), findsOneWidget);
      expect(find.text(LeakSentryCopy.leaksEmptyTitle), findsNothing);
    });

    testWidgets('clearing the leaks empties the list', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await pumpScreen(tester, f);

      f.engine.clearLeaks();
      await tester.pump();

      expect(find.byType(LeakCard), findsNothing);
      expect(find.text(LeakSentryCopy.leaksEmptyTitle), findsOneWidget);
    });

    testWidgets('the Leaks tab says how many leaks have not been opened', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport(signature: 'one'), leakReport(type: PageFourState, signature: 'two')]);

      await pumpScreen(tester, f);

      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('2')), findsOneWidget);
    });
  });

  group('the count on the tab', () {
    testWidgets('is a disc ringed in the colour of the bar, so that it does not run into the icon', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await pumpScreen(tester, f);

      final badge = tester.widget<Badge>(find.descendant(of: find.byType(NavigationBar), matching: find.byType(Badge)));

      expect(badge.isLabelVisible, isTrue);
      final disc = (badge.label! as DecoratedBox).decoration as BoxDecoration;
      expect(disc.color, LeakSentryColors.accent);
      expect((disc.border! as Border).top.color, LeakSentryColors.surface);
    });
  });

  group('opening a leak', () {
    testWidgets('shows it, reads it, and the NEW tag and the count on the tab go', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await pumpScreen(tester, f);
      expect(f.engine.catalog.unreadCount, 1);

      await tester.tap(find.byType(LeakCard));
      await tester.pumpAndSettle();

      expect(find.text(LeakSentryCopy.whereCreated), findsOneWidget);
      expect(f.engine.catalog.unreadCount, 0);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('NEW'), findsNothing);
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.byType(Badge)), findsOneWidget);
      expect(tester.widget<Badge>(find.descendant(of: find.byType(NavigationBar), matching: find.byType(Badge))).isLabelVisible, isFalse);
    });

    testWidgets('going back returns to the list, on the same tab', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await pumpScreen(tester, f);

      await tester.tap(find.byType(LeakCard));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(LeakCard), findsOneWidget);
    });
  });

  group('the tabs', () {
    testWidgets('opens on the tab it is asked to', (tester) async {
      await pumpScreen(tester, f, tab: LeakSentryTab.settings);

      expect(find.descendant(of: find.byType(AppBar), matching: find.text('Settings')), findsOneWidget);
      expect(find.text(LeakSentryCopy.settingsScanAutomatically), findsOneWidget);
    });

    testWidgets('moves between them, and the title follows', (tester) async {
      await pumpScreen(tester, f);

      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Scans')));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(AppBar), matching: find.text('Scans')), findsOneWidget);
      expect(find.text(LeakSentryCopy.scanNow), findsOneWidget);

      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Settings')));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(AppBar), matching: find.text('Settings')), findsOneWidget);

      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Leaks')));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(AppBar), matching: find.text('Leaks')), findsOneWidget);
    });
  });

  group('whatever the screen', () {
    for (final (scale, width) in const [(1.0, 400.0), (1.5, 400.0), (1.0, 320.0), (1.5, 320.0)]) {
      testWidgets('lists leaks at text scale $scale, $width wide', (tester) async {
        runScan(f.engine.catalog, 'a', [
          leakReport(type: LeakyOther, count: 120, signature: 'long', created: const CreationSite(uri: 'package:a_package_with_a_rather_long_name/some/nested/directory/a_long_file_name.dart', member: '_AnExtremelyLongNamedStateClassForTestingState.initState', line: 12345, column: 7)),
          leakReport(type: PageFourState, signature: 'plain'),
        ]);

        await pumpScreen(tester, f, textScale: scale, width: width);

        expect(tester.takeException(), isNull);
        expect(find.byType(LeakCard), findsNWidgets(2));
      });
    }

    testWidgets('keeps its content to a readable width on a wide screen', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);

      await pumpScreen(tester, f, width: 1400, height: 900);

      expect(tester.getSize(find.byType(LeakCard)).width, lessThanOrEqualTo(640));
      expect(tester.takeException(), isNull);
    });
  });
}

class LeakyOther {}
