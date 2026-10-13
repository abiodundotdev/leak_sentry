import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/leak_sentry_tab.dart';
import 'package:leak_sentry/ui/leak_sentry_screen.dart';
import 'package:leak_sentry/ui/tokens.dart';

import 'engine_fixture.dart';

/// Pumps [child] the way a LeakSentry screen shows it: on the screens' theme,
/// at the text scale and width a test asks for.
///
/// Flutter's tests draw text in a font whose every letter is a full square, so
/// text is wider here than on a device. What fits here fits there.
Future<void> pumpUi(
  WidgetTester tester,
  Widget child, {
  double textScale = 1.0,
  double width = 400,
  double height = 900,
  bool scrollable = true,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      theme: LeakSentryTheme.data(),
      home: Scaffold(
        body: scrollable
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(LeakSentryMetrics.pagePadding),
                child: child,
              )
            : child,
      ),
    ),
  );
}

/// Records what is copied to the clipboard for the rest of the test.
List<String> captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

/// Pumps the LeakSentry screen for the engine of [f], in an app with a navigator.
Future<void> pumpScreen(
  WidgetTester tester,
  EngineFixture f, {
  LeakSentryTab tab = LeakSentryTab.leaks,
  double textScale = 1.0,
  double width = 400,
  double height = 900,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(MaterialApp(home: LeakSentryScreen.withEngine(engine: f.engine, initialTab: tab)));
}
