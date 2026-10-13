import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/heap_dump_control.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';
import 'package:leak_sentry/core/leak_sentry_tab.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/tokens.dart';

import '../helpers/capture_log.dart';
import '../helpers/engine_fixture.dart';
import '../helpers/leak_events.dart';
import '../helpers/pump_ui.dart';

Finder get _switch => find.byType(Switch);

Finder _stepper(IconData icon) => find.widgetWithIcon(IconButton, icon);

bool _isEnabled(WidgetTester tester, Finder button) => tester.widget<IconButton>(button).onPressed != null;

void main() {
  late EngineFixture f;

  setUp(() {
    captureLog();
    f = EngineFixture();
  });

  tearDown(() => f.engine.dispose());

  Future<void> pumpSettings(WidgetTester tester, {double textScale = 1.0, double width = 400}) =>
      pumpScreen(tester, f, tab: LeakSentryTab.settings, textScale: textScale, width: width);

  group('scanning automatically', () {
    testWidgets('is on, until it is switched off', (tester) async {
      await pumpSettings(tester);

      expect(find.text(LeakSentryCopy.settingsScanAutomatically), findsOneWidget);
      expect(tester.widget<Switch>(_switch).value, isTrue);
    });

    testWidgets('switching it off turns it off in the engine, and the status says so', (tester) async {
      f.engine.install(watchers: const []);
      await pumpSettings(tester);
      expect(find.text(LeakSentryCopy.settingsScanningOn), findsOneWidget);

      await tester.tap(_switch);
      await tester.pump();

      expect(f.engine.dumpEnabledInAboutScreen, isFalse);
      expect(tester.widget<Switch>(_switch).value, isFalse);
      expect(find.text(LeakSentryCopy.blockShort(HeapDumpBlock.switchedOffInSettings)), findsOneWidget);
      expect(find.text(LeakSentryCopy.settingsScanningOn), findsNothing);
    });

    testWidgets('and back on', (tester) async {
      f.engine.install(watchers: const []);
      f.engine.dumpEnabledInAboutScreen = false;
      await pumpSettings(tester);

      await tester.tap(_switch);
      await tester.pump();

      expect(f.engine.dumpEnabledInAboutScreen, isTrue);
      expect(find.text(LeakSentryCopy.settingsScanningOn), findsOneWidget);
    });
  });

  group('how many objects are held before scanning', () {
    testWidgets('is the threshold of the config, and the buttons change it', (tester) async {
      await pumpSettings(tester);
      expect(find.text('5'), findsOneWidget);

      await tester.tap(_stepper(Icons.add_circle_outline));
      await tester.pump();
      expect(f.engine.config.retainedVisibleThreshold, 6);
      expect(find.text('6'), findsOneWidget);

      await tester.tap(_stepper(Icons.remove_circle_outline));
      await tester.tap(_stepper(Icons.remove_circle_outline));
      await tester.pump();
      expect(f.engine.config.retainedVisibleThreshold, 4);
      expect(find.text('4'), findsOneWidget);
    });

    testWidgets('changes nothing else in the config', (tester) async {
      f.engine.config = const LeakSentryConfig(maxRetainingPathLookups: 7, enableRetainingPathAnalysis: false);
      await pumpSettings(tester);

      await tester.tap(_stepper(Icons.add_circle_outline));
      await tester.pump();

      expect(f.engine.config.maxRetainingPathLookups, 7);
      expect(f.engine.config.enableRetainingPathAnalysis, isFalse);
      expect(f.engine.config.retainedVisibleThreshold, 6);
    });

    testWidgets('cannot go below one', (tester) async {
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 1);
      await pumpSettings(tester);

      expect(_isEnabled(tester, _stepper(Icons.remove_circle_outline)), isFalse);
      expect(_isEnabled(tester, _stepper(Icons.add_circle_outline)), isTrue);
    });

    testWidgets('cannot go above fifty', (tester) async {
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 50);
      await pumpSettings(tester);

      expect(_isEnabled(tester, _stepper(Icons.add_circle_outline)), isFalse);
      expect(_isEnabled(tester, _stepper(Icons.remove_circle_outline)), isTrue);
    });

    testWidgets('one step from the limits can still step to them', (tester) async {
      f.engine.config = const LeakSentryConfig(retainedVisibleThreshold: 2);
      await pumpSettings(tester);
      expect(_isEnabled(tester, _stepper(Icons.remove_circle_outline)), isTrue);

      await tester.tap(_stepper(Icons.remove_circle_outline));
      await tester.pump();

      expect(f.engine.config.retainedVisibleThreshold, 1);
      expect(_isEnabled(tester, _stepper(Icons.remove_circle_outline)), isFalse);
    });
  });

  group('the status', () {
    testWidgets('says whether the VM service can be reached', (tester) async {
      await pumpSettings(tester);
      await tester.pump();

      expect(find.text(LeakSentryCopy.settingsVmReachable), findsOneWidget);
      expect(find.text(LeakSentryCopy.settingsVmYes), findsOneWidget);
    });

    testWidgets('and says so when it cannot', (tester) async {
      f.vm.reachable = false;
      await pumpSettings(tester);
      await tester.pump();

      expect(find.text(LeakSentryCopy.settingsVmNo), findsOneWidget);
      expect(find.text(LeakSentryCopy.settingsVmYes), findsNothing);
    });

    testWidgets('says what the build is', (tester) async {
      await pumpSettings(tester);

      expect(find.text(LeakSentryCopy.settingsBuildMode), findsOneWidget);
      expect(find.text(LeakSentryCopy.settingsBuildDebug), findsOneWidget, reason: 'tests run in debug mode');
    });

    testWidgets('says what keeps it from scanning, when something does', (tester) async {
      await pumpSettings(tester);

      expect(find.text(LeakSentryCopy.blockShort(HeapDumpBlock.notInstalled)), findsOneWidget);
    });

    testWidgets('says the config turned it off, when it did', (tester) async {
      f.engine.install(watchers: const []);
      f.engine.config = const LeakSentryConfig(dumpHeap: false);
      await pumpSettings(tester);

      expect(find.text(LeakSentryCopy.blockShort(HeapDumpBlock.disabledByConfig)), findsOneWidget);
    });
  });

  group('what the sections are called', () {
    testWidgets('does not repeat the name of the tab: the first one is about scanning on its own', (tester) async {
      await pumpSettings(tester);

      expect(find.text(LeakSentryCopy.settingsScansSection), findsOneWidget);
      expect(LeakSentryCopy.settingsScansSection, isNot(LeakSentryCopy.tabScans));
    });
  });

  group('clearing everything', () {
    testWidgets('asks first, and keeps everything if the answer is no', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);
      await pumpSettings(tester);

      await tester.tap(find.text(LeakSentryCopy.settingsClear));
      await tester.pumpAndSettle();
      expect(find.text(LeakSentryCopy.settingsClearConfirmTitle), findsOneWidget);
      expect(find.text(LeakSentryCopy.settingsClearConfirmBody), findsOneWidget);

      await tester.tap(find.text(LeakSentryCopy.settingsClearCancel));
      await tester.pumpAndSettle();

      expect(find.text(LeakSentryCopy.settingsClearConfirmTitle), findsNothing);
      expect(f.engine.catalog.groups, hasLength(1));
      expect(f.engine.catalog.scans, hasLength(1));
    });

    testWidgets('forgets every leak and scan if the answer is yes, and says so', (tester) async {
      runScan(f.engine.catalog, 'a', [leakReport()]);
      f.engine.hub.add(leakReport());
      await pumpSettings(tester);

      await tester.tap(find.text(LeakSentryCopy.settingsClear));
      await tester.pumpAndSettle();
      await tester.tap(find.text(LeakSentryCopy.settingsClearConfirm));
      await tester.pumpAndSettle();

      expect(f.engine.catalog.groups, isEmpty);
      expect(f.engine.catalog.scans, isEmpty);
      expect(f.engine.hub.leakHistory, isEmpty);
      expect(find.text(LeakSentryCopy.settingsCleared), findsOneWidget);
    });

    testWidgets('is drawn as what cannot be undone: coral, not the mint of what is good to press', (tester) async {
      await pumpSettings(tester);

      final clear = tester.widget<OutlinedButton>(
        find.ancestor(of: find.text(LeakSentryCopy.settingsClear), matching: find.byWidgetPredicate((widget) => widget is OutlinedButton)),
      );
      expect(clear.style!.foregroundColor!.resolve({}), LeakSentryColors.dangerText);

      await tester.tap(find.text(LeakSentryCopy.settingsClear));
      await tester.pumpAndSettle();

      final confirm = tester.widget<FilledButton>(find.widgetWithText(FilledButton, LeakSentryCopy.settingsClearConfirm));
      expect(confirm.style!.backgroundColor!.resolve({}), LeakSentryColors.danger);
      expect(confirm.style!.foregroundColor!.resolve({}), LeakSentryColors.onAccent);
    });

    testWidgets('says that what it lists is kept for this session only', (tester) async {
      await pumpSettings(tester);

      expect(find.text(LeakSentryCopy.thisSession), findsOneWidget);
    });
  });

  group('whatever the screen', () {
    for (final (scale, width) in const [(1.0, 400.0), (1.5, 400.0), (1.0, 320.0), (1.5, 320.0)]) {
      testWidgets('shows the settings at text scale $scale, $width wide', (tester) async {
        await pumpSettings(tester, textScale: scale, width: width);
        await tester.pump();

        expect(tester.takeException(), isNull);
      });

      testWidgets('shows the confirmation at text scale $scale, $width wide', (tester) async {
        await pumpSettings(tester, textScale: scale, width: width);
        await tester.ensureVisible(find.text(LeakSentryCopy.settingsClear));
        await tester.pump();

        await tester.tap(find.text(LeakSentryCopy.settingsClear));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text(LeakSentryCopy.settingsClearConfirmTitle), findsOneWidget);
      });
    }
  });
}
