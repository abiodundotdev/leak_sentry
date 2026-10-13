import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/object_watcher/default_watchers.dart';
import 'package:leak_sentry/object_watcher/deletable_object_reporter.dart';
import 'package:leak_sentry/object_watcher/installable_watcher.dart';
import 'package:leak_sentry/object_watcher/object_event_router.dart';

class _TestState extends State<StatefulWidget> {
  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _TestRoute extends Route<void> {}

class _Plain {}

class _Reporter implements DeletableObjectReporter {
  final List<(Object, String)> reported = [];

  @override
  TrackedObjectReachability expectDeletionFor(Object target, String reason) {
    reported.add((target, reason));
    return const UntrackedObjectReachability();
  }

  List<String> get reasons => [for (final (_, reason) in reported) reason];
}

void _dispatchDisposed(Object object) =>
    FlutterMemoryAllocations.instance.dispatchObjectEvent(ObjectDisposed(object: object));

void main() {
  late ObjectEventRouter router;
  late _Reporter reporter;
  late List<InstallableWatcher> installed;

  T install<T extends InstallableWatcher>(T watcher) {
    watcher.install();
    installed.add(watcher);
    return watcher;
  }

  setUp(() {
    router = ObjectEventRouter();
    reporter = _Reporter();
    installed = [];
  });

  tearDown(() {
    for (final watcher in installed) {
      watcher.uninstall();
    }
  });

  group('reasons', () {
    test('a State is expected to be collected after dispose()', () {
      install(StateWatcher(reporter, router: router));
      final state = _TestState();

      _dispatchDisposed(state);

      expect(reporter.reported.single.$1, same(state));
      expect(reporter.reasons.single, '_TestState received State#dispose() callback');
    });

    test('a Route is expected to be collected after dispose()', () {
      install(RouteWatcher(reporter, router: router));

      _dispatchDisposed(_TestRoute());

      expect(reporter.reasons.single, '_TestRoute received Route#dispose() callback');
    });

    test('a ChangeNotifier is expected to be collected after dispose(), through Flutter itself', () {
      install(ChangeNotifierWatcher(reporter, router: router));
      final notifier = ValueNotifier<int>(0);

      notifier.dispose();

      expect(reporter.reported.single.$1, same(notifier));
      expect(reporter.reasons.single, 'ValueNotifier<int> received ChangeNotifier#dispose() callback');
    });

    test('an AnimationController is expected to be collected after dispose(), through Flutter itself', () {
      install(AnimationControllerWatcher(reporter, router: router));
      final controller = AnimationController(vsync: const TestVSync());

      controller.dispose();

      expect(reporter.reported.single.$1, same(controller));
      expect(reporter.reasons.single, 'AnimationController received AnimationController#dispose() callback');
    });

    test('any disposed object is expected to be collected by the opt-in watcher', () {
      install(AllDisposedObjectsWatcher(reporter, router: router));
      final plain = _Plain();

      _dispatchDisposed(plain);

      expect(reporter.reported.single.$1, same(plain));
      expect(reporter.reasons.single, '_Plain was disposed');
    });
  });

  group('what each one watches', () {
    test('only its own type', () {
      install(StateWatcher(reporter, router: router));
      install(RouteWatcher(reporter, router: router));

      _dispatchDisposed(ValueNotifier<int>(0));
      _dispatchDisposed(_Plain());

      expect(reporter.reported, isEmpty);
    });

    test('a ChangeNotifier watcher leaves States alone, and the other way round', () {
      install(ChangeNotifierWatcher(reporter, router: router));
      _dispatchDisposed(_TestState());
      expect(reporter.reported, isEmpty);
    });

    test('together they report each object once', () {
      install(StateWatcher(reporter, router: router));
      install(RouteWatcher(reporter, router: router));
      install(ChangeNotifierWatcher(reporter, router: router));
      install(AnimationControllerWatcher(reporter, router: router));

      _dispatchDisposed(_TestState());
      _dispatchDisposed(_TestRoute());
      ValueNotifier<int>(0).dispose();
      AnimationController(vsync: const TestVSync()).dispose();

      expect(reporter.reasons, [
        '_TestState received State#dispose() callback',
        '_TestRoute received Route#dispose() callback',
        'ValueNotifier<int> received ChangeNotifier#dispose() callback',
        'AnimationController received AnimationController#dispose() callback',
      ]);
    });
  });

  group('installing', () {
    test('installing twice throws', () {
      final watcher = install(StateWatcher(reporter, router: router));

      expect(watcher.install, throwsA(isA<StateError>().having((e) => e.message, 'message', contains('StateWatcher'))));
    });

    test('uninstalling stops it, and it can be installed again', () {
      final watcher = StateWatcher(reporter, router: router)..install();
      watcher.uninstall();

      _dispatchDisposed(_TestState());
      expect(reporter.reported, isEmpty);

      install(watcher);
      _dispatchDisposed(_TestState());
      expect(reporter.reported, hasLength(1));
    });

    test('uninstalling a watcher that was never installed is harmless', () {
      expect(StateWatcher(reporter, router: router).uninstall, returnsNormally);
    });
  });
}
