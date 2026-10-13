import 'package:flutter/animation.dart' show AnimationController;
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/widgets.dart' show Route, State;
import 'package:leak_sentry/object_watcher/deletable_object_reporter.dart';
import 'package:leak_sentry/object_watcher/installable_watcher.dart';
import 'package:leak_sentry/object_watcher/object_event_router.dart';

/// Expects every object of type [T] to be garbage collected soon after Flutter
/// reports it disposed.
abstract class DisposalWatcher<T extends Object> implements InstallableWatcher {
  DisposalWatcher(DeletableObjectReporter deletableObjectReporter, {ObjectEventRouter? router})
    : _reporter = deletableObjectReporter,
      _router = router ?? ObjectEventRouter.shared;

  final DeletableObjectReporter _reporter;
  final ObjectEventRouter _router;
  ObjectEventSubscription? _subscription;

  /// Why [object] should be collected, which is shown in the leak report.
  String describe(T object);

  @override
  void install() {
    if (_subscription != null) throw StateError('$runtimeType already installed');
    _subscription = _router.listenForDisposal<T>((object) => _reporter.expectDeletionFor(object, describe(object)));
  }

  @override
  void uninstall() {
    _subscription?.cancel();
    _subscription = null;
  }
}

/// Expects a `State` to be collected soon after `State.dispose()`.
class StateWatcher extends DisposalWatcher<State> {
  StateWatcher(super.deletableObjectReporter, {super.router});

  @override
  String describe(State object) => '${object.runtimeType} received State#dispose() callback';
}

/// Expects a `Route` to be collected soon after `Route.dispose()`, once it has
/// left the navigator and finished its exit transition.
class RouteWatcher extends DisposalWatcher<Route> {
  RouteWatcher(super.deletableObjectReporter, {super.router});

  @override
  String describe(Route object) => '${object.runtimeType} received Route#dispose() callback';
}

/// Expects a `ChangeNotifier` to be collected soon after
/// `ChangeNotifier.dispose()`. View models, controllers, focus nodes and value
/// notifiers are all change notifiers, so this one watcher covers them all.
class ChangeNotifierWatcher extends DisposalWatcher<ChangeNotifier> {
  ChangeNotifierWatcher(super.deletableObjectReporter, {super.router});

  @override
  String describe(ChangeNotifier object) => '${object.runtimeType} received ChangeNotifier#dispose() callback';
}

/// Expects an `AnimationController` to be collected soon after
/// `AnimationController.dispose()`.
class AnimationControllerWatcher extends DisposalWatcher<AnimationController> {
  AnimationControllerWatcher(super.deletableObjectReporter, {super.router});

  @override
  String describe(AnimationController object) =>
      '${object.runtimeType} received AnimationController#dispose() callback';
}

/// Expects every object Flutter reports disposed to be collected, elements and
/// render objects included. Not one of the defaults: it is noisy, and a
/// creation stack is only captured for what is not framework churn.
class AllDisposedObjectsWatcher extends DisposalWatcher<Object> {
  AllDisposedObjectsWatcher(super.deletableObjectReporter, {super.router});

  @override
  String describe(Object object) => '${object.runtimeType} was disposed';
}
