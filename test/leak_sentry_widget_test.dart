import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/internal_leak_sentry.dart';
import 'package:leak_sentry/widgets/leak_sentry_widget.dart';

import 'helpers/engine_fixture.dart';

void main() {
  tearDown(LeakSentry.resetForTesting);

  testWidgets('mounting installs LeakSentry and shows the child', (tester) async {
    final f = EngineFixture();
    InternalLeakSentryHolder.use(f);
    expect(f.engine.isInstalled, isFalse);

    await tester.pumpWidget(const LeakSentry(child: Text('app', textDirection: TextDirection.ltr)));

    expect(f.engine.isInstalled, isTrue);
    expect(find.text('app'), findsOneWidget);
  });

  testWidgets('mounting it more than once installs once', (tester) async {
    final f = EngineFixture();
    InternalLeakSentryHolder.use(f);

    await tester.pumpWidget(const LeakSentry(child: LeakSentry(child: SizedBox())));

    expect(f.engine.isInstalled, isTrue);
  });

  testWidgets('rebuilding does not install again', (tester) async {
    final f = EngineFixture();
    InternalLeakSentryHolder.use(f);

    await tester.pumpWidget(const LeakSentry(child: Text('a', textDirection: TextDirection.ltr)));
    await tester.pumpWidget(const LeakSentry(child: Text('b', textDirection: TextDirection.ltr)));

    expect(f.engine.isInstalled, isTrue);
    expect(find.text('b'), findsOneWidget);
  });

  testWidgets('unmounting the widget leaves LeakSentry installed', (tester) async {
    final f = EngineFixture();
    InternalLeakSentryHolder.use(f);
    await tester.pumpWidget(const LeakSentry(child: SizedBox()));

    await tester.pumpWidget(const SizedBox());

    expect(f.engine.isInstalled, isTrue);
  });

  testWidgets('an explicit install before mounting is left alone', (tester) async {
    final f = EngineFixture();
    InternalLeakSentryHolder.use(f);
    f.engine.install(retainedDelay: const Duration(seconds: 9), watchers: const []);

    await tester.pumpWidget(const LeakSentry(child: SizedBox()));

    expect(f.engine.retainedDelay, const Duration(seconds: 9));
  });

  testWidgets('does nothing in a release build', (tester) async {
    final f = EngineFixture(release: true);
    InternalLeakSentryHolder.use(f);

    await tester.pumpWidget(const LeakSentry(child: Text('app', textDirection: TextDirection.ltr)));

    expect(f.engine.isInstalled, isFalse);
    expect(find.text('app'), findsOneWidget);
  });

  testWidgets('does nothing under flutter test, so it cannot leave timers behind in an app\'s own tests', (tester) async {
    // The default engine detects the test environment itself.
    InternalLeakSentry.instance = InternalLeakSentry();

    await tester.pumpWidget(const LeakSentry(child: Text('app', textDirection: TextDirection.ltr)));
    await tester.pumpWidget(const SizedBox());

    expect(LeakSentry.isInstalled, isFalse);
    // The test ends with no pending timer, which testWidgets checks.
  });
}
