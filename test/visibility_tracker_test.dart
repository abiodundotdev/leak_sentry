import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/visibility_tracker.dart';

void main() {
  // First, because a lifecycle state, once reported, stays for the rest of the file.
  testWidgets('assumes the app is visible while the platform has not reported a lifecycle state', (tester) async {
    expect(
      tester.binding.lifecycleState,
      isNull,
      reason: 'this test needs a binding that has not been given a lifecycle state yet',
    );
    final changes = <bool>[];

    final tracker = LifecycleVisibilityTracker()..start(changes.add);
    expect(changes, isEmpty, reason: 'the app is running, so it is visible');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);

    expect(changes, [false], reason: 'it was assumed visible, so hiding it is a change');
    tracker.stop();
  });

  testWidgets('reports when the app becomes invisible and visible again', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final changes = <bool>[];
    final tracker = LifecycleVisibilityTracker()..start(changes.add);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(changes, isEmpty, reason: 'an inactive app (a dialog, split screen) is still visible');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(changes, [false]);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(changes, [false], reason: 'hidden to paused is no change');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(changes, [false, true]);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(changes, [false, true]);

    tracker.stop();
  });

  testWidgets('a detached app is invisible', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final changes = <bool>[];
    final tracker = LifecycleVisibilityTracker()..start(changes.add);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);

    expect(changes, [false]);
    tracker.stop();
  });

  testWidgets('reports an app that is already in the background when it starts', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final changes = <bool>[];

    final tracker = LifecycleVisibilityTracker()..start(changes.add);

    expect(changes, [false]);
    tracker.stop();
  });

  testWidgets('reports nothing at the start when the app is visible', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final changes = <bool>[];

    final tracker = LifecycleVisibilityTracker()..start(changes.add);

    expect(changes, isEmpty);
    tracker.stop();
  });

  testWidgets('stops reporting once stopped', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final changes = <bool>[];
    final tracker = LifecycleVisibilityTracker()..start(changes.add);

    tracker.stop();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);

    expect(changes, isEmpty);
  });

  testWidgets('starting twice keeps the first listener, and stopping twice is harmless', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final first = <bool>[];
    final second = <bool>[];
    final tracker = LifecycleVisibilityTracker()
      ..start(first.add)
      ..start(second.add);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);

    expect(first, [false]);
    expect(second, isEmpty);
    tracker
      ..stop()
      ..stop();
  });
}
