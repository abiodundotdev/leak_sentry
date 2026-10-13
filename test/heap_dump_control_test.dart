import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/heap_dump_control.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';

void main() {
  late bool installed;
  late LeakSentryConfig config;
  late bool dumpEnabledInAboutScreen;
  late String? testEnvironment;
  late int scheduledChecks;
  late HeapDumpControl control;

  setUp(() {
    installed = true;
    config = const LeakSentryConfig();
    dumpEnabledInAboutScreen = true;
    testEnvironment = null;
    scheduledChecks = 0;
    control = HeapDumpControl(
      isInstalled: () => installed,
      config: () => config,
      dumpEnabledInAboutScreen: () => dumpEnabledInAboutScreen,
      testEnvironment: () => testEnvironment,
      scheduleRetainedObjectCheck: () => scheduledChecks++,
    );
  });

  test('says yes when nothing forbids it', () {
    expect(control.iCanHasHeap(), isA<Yup>());
  });

  test('says a silent no when not installed', () {
    installed = false;

    final result = control.iCanHasHeap();

    expect(result, isA<SilentNope>());
    expect((result as Nope).reason(), 'LeakSentry is not installed.');
  });

  test('says what stops it as data, so a screen need not read the wording', () {
    installed = false;
    expect((control.iCanHasHeap() as Nope).block, HeapDumpBlock.notInstalled);
    installed = true;

    dumpEnabledInAboutScreen = false;
    expect((control.iCanHasHeap() as Nope).block, HeapDumpBlock.switchedOffInSettings);
    dumpEnabledInAboutScreen = true;

    config = const LeakSentryConfig(dumpHeap: false);
    expect((control.iCanHasHeap() as Nope).block, HeapDumpBlock.disabledByConfig);
    config = const LeakSentryConfig();

    testEnvironment = 'FLUTTER_TEST';
    expect((control.iCanHasHeap() as Nope).block, HeapDumpBlock.runningTests);
  });

  group('peeking', () {
    test('gives the answer iCanHasHeap would, for every cause', () {
      expect(control.peek(), isA<Yup>());
      installed = false;
      expect((control.peek() as Nope).block, HeapDumpBlock.notInstalled);
      installed = true;
      dumpEnabledInAboutScreen = false;
      expect((control.peek() as Nope).block, HeapDumpBlock.switchedOffInSettings);
      expect(control.peek(), isA<NotifyingNope>());
      dumpEnabledInAboutScreen = true;
      config = const LeakSentryConfig(dumpHeap: false);
      expect((control.peek() as Nope).block, HeapDumpBlock.disabledByConfig);
      config = const LeakSentryConfig();
      testEnvironment = 'FLUTTER_TEST';
      expect((control.peek() as Nope).block, HeapDumpBlock.runningTests);
    });

    test('has no effect: going from no to yes is only noticed by the next real check', () {
      dumpEnabledInAboutScreen = false;
      control.iCanHasHeap();
      dumpEnabledInAboutScreen = true;

      control.peek();
      control.peek();

      expect(scheduledChecks, 0, reason: 'a screen asking while it builds must not schedule a check');
      control.iCanHasHeap();
      expect(scheduledChecks, 1);
    });
  });

  test('says a notifying no when dumping was turned off in the Settings tab', () {
    dumpEnabledInAboutScreen = false;

    final result = control.iCanHasHeap();

    expect(result, isA<NotifyingNope>());
    expect((result as Nope).reason(), 'heap dumping disabled from the LeakSentry Settings screen');
  });

  test('says a silent no when the config turns dumping off', () {
    config = const LeakSentryConfig(dumpHeap: false);

    final result = control.iCanHasHeap();

    expect(result, isA<SilentNope>());
    expect((result as Nope).reason(), 'LeakSentryConfig.dumpHeap is set to false');
  });

  test('says a silent no in a test environment, and names it', () {
    testEnvironment = 'FLUTTER_TEST';

    final result = control.iCanHasHeap();

    expect(result, isA<SilentNope>());
    expect((result as Nope).reason(), contains('FLUTTER_TEST'));
  });

  test('checks in this order: installed, Settings switch, config, test environment', () {
    installed = false;
    dumpEnabledInAboutScreen = false;
    config = const LeakSentryConfig(dumpHeap: false);
    testEnvironment = 'FLUTTER_TEST';
    expect(((control.iCanHasHeap()) as Nope).reason(), contains('not installed'));

    installed = true;
    expect(control.iCanHasHeap(), isA<NotifyingNope>());

    dumpEnabledInAboutScreen = true;
    expect(((control.iCanHasHeap()) as Nope).reason(), contains('dumpHeap is set to false'));

    config = const LeakSentryConfig();
    expect(((control.iCanHasHeap()) as Nope).reason(), contains('FLUTTER_TEST'));

    testEnvironment = null;
    expect(control.iCanHasHeap(), isA<Yup>());
  });

  group('going from no to yes', () {
    test('schedules a check, once', () {
      dumpEnabledInAboutScreen = false;
      control.iCanHasHeap();
      expect(scheduledChecks, 0);

      dumpEnabledInAboutScreen = true;
      control.iCanHasHeap();
      control.iCanHasHeap();

      expect(scheduledChecks, 1);
    });

    test('is not needed the first time, when nothing came before', () {
      control.iCanHasHeap();

      expect(scheduledChecks, 0);
    });

    test('is not needed when the answer stays the same', () {
      dumpEnabledInAboutScreen = false;
      control.iCanHasHeap();
      control.iCanHasHeap();
      expect(scheduledChecks, 0);

      dumpEnabledInAboutScreen = true;
      control.iCanHasHeap();
      scheduledChecks = 0;
      control.iCanHasHeap();
      expect(scheduledChecks, 0);
    });

    test('goes from silent to yes too', () {
      config = const LeakSentryConfig(dumpHeap: false);
      control.iCanHasHeap();

      config = const LeakSentryConfig();
      control.iCanHasHeap();

      expect(scheduledChecks, 1);
    });
  });
}
