import 'package:leak_sentry/core/leak_sentry_config.dart';
import 'package:leak_sentry/core/leak_sentry_strings.dart';

/// Whether the heap may be dumped right now.
sealed class ICanHazHeap {
  const ICanHazHeap();
}

/// The heap may be dumped.
final class Yup extends ICanHazHeap {
  const Yup();
}

/// What stops the heap from being dumped, as data, so that a screen need not
/// read it out of the log wording.
enum HeapDumpBlock {
  /// LeakSentry is not installed.
  notInstalled,

  /// The "Scan automatically" switch of the Settings tab is off.
  switchedOffInSettings,

  /// `LeakSentryConfig.dumpHeap` is false.
  disabledByConfig,

  /// The app runs in a test environment.
  runningTests,
}

/// The heap may not be dumped, for [reason], which is [block].
sealed class Nope extends ICanHazHeap {
  const Nope(this.reason, this.block);

  final String Function() reason;
  final HeapDumpBlock block;
}

/// Not dumping is nothing to bother the developer about.
final class SilentNope extends Nope {
  const SilentNope(super.reason, super.block);
}

/// Not dumping is worth telling the developer, who can still dump manually.
final class NotifyingNope extends Nope {
  const NotifyingNope(super.reason, super.block);
}

/// Decides whether the heap may be dumped.
class HeapDumpControl {
  HeapDumpControl({
    required bool Function() isInstalled,
    required LeakSentryConfig Function() config,
    required bool Function() dumpEnabledInAboutScreen,
    required String? Function() testEnvironment,
    required void Function() scheduleRetainedObjectCheck,
  }) : _isInstalled = isInstalled,
       _config = config,
       _dumpEnabledInAboutScreen = dumpEnabledInAboutScreen,
       _testEnvironment = testEnvironment,
       _scheduleRetainedObjectCheck = scheduleRetainedObjectCheck;

  final bool Function() _isInstalled;
  final LeakSentryConfig Function() _config;
  final bool Function() _dumpEnabledInAboutScreen;

  /// The name of the test environment the app runs in, or null.
  final String? Function() _testEnvironment;
  final void Function() _scheduleRetainedObjectCheck;

  ICanHazHeap? _latest;

  /// Works out whether the heap may be dumped. Going from no to yes schedules a
  /// retained-object check, so objects that piled up meanwhile are looked at.
  ICanHazHeap iCanHasHeap() {
    final dumpHeap = peek();
    if (_latest is Nope && dumpHeap is Yup) _scheduleRetainedObjectCheck();
    _latest = dumpHeap;
    return dumpHeap;
  }

  /// The same answer as [iCanHasHeap], without any of its effects: a screen can
  /// ask as often as it builds.
  ICanHazHeap peek() {
    final testEnvironment = _testEnvironment();
    if (!_isInstalled()) return const SilentNope(_notInstalled, HeapDumpBlock.notInstalled);
    if (!_dumpEnabledInAboutScreen()) return const NotifyingNope(_disabledFromUi, HeapDumpBlock.switchedOffInSettings);
    if (!_config().dumpHeap) return const SilentNope(_disabledByApp, HeapDumpBlock.disabledByConfig);
    if (testEnvironment != null) {
      return SilentNope(
        () => LeakSentryStrings.heapDumpDisabledRunningTests(testEnvironment),
        HeapDumpBlock.runningTests,
      );
    }
    return const Yup();
  }

  static String _notInstalled() => LeakSentryStrings.notInstalled;

  static String _disabledFromUi() => LeakSentryStrings.heapDumpDisabledFromUi;

  static String _disabledByApp() => LeakSentryStrings.heapDumpDisabledByApp;
}
