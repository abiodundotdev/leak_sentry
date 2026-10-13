import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/analysis/node_status.dart';
import 'package:leak_sentry/models/field_facts.dart';

/// What an inspector makes of a step of a path, and why.
class NodeFinding {
  const NodeFinding.inUse(this.reason) : status = NodeStatus.inUse;

  const NodeFinding.shouldBeGone(this.reason) : status = NodeStatus.shouldBeGone;

  final NodeStatus status;

  /// In a sentence, why. It is shown under the step.
  final String reason;
}

/// A step of a path, with everything that is known about it, for an inspector to
/// look at.
class InspectedNode {
  const InspectedNode({
    required this.node,
    required this.isLeakedObject,
    this.facts,
    this.leakedReason,
    this.alsoExpectedGone,
  });

  final TraceNode node;

  /// Whether this is the object that leaked, the last step of the path.
  final bool isLeakedObject;

  /// What the VM said about the fields of the object, if it was asked.
  final FieldFacts? facts;

  /// Why the leaked object was expected to be gone. Only for the leaked object.
  final String? leakedReason;

  /// Why this object was expected to be gone, if it is another object that is
  /// watched and retained, which a leak can pass through.
  final String? alsoExpectedGone;
}

/// Says what a step of a path is: in use, or something that should be gone, or
/// nothing.
abstract interface class NodeInspector {
  /// A finding, or null when this inspector has nothing to say about [node].
  NodeFinding? inspect(InspectedNode node);
}

/// The inspectors that need only the path: they are what the fingerprint of a leak is
/// made from, so what they say must not depend on anything that can fail.
const List<NodeInspector> structuralInspectors = [
  LeakedObjectInspector(),
  StaticHolderInspector(),
  RuntimeInternalsInspector(),
  FrameworkSingletonInspector(),
  OtherWatchedObjectInspector(),
];

/// The inspectors that need to know what is in an object's fields.
const List<NodeInspector> fieldInspectors = [
  ChangeNotifierInspector(),
  StateInspector(),
  ElementInspector(),
  RouteInspector(),
  AnimationControllerInspector(),
  RenderObjectInspector(),
];

/// The object that leaked is the one that should be gone.
class LeakedObjectInspector implements NodeInspector {
  const LeakedObjectInspector();

  @override
  NodeFinding? inspect(InspectedNode node) {
    if (!node.isLeakedObject) return null;
    final reason = node.leakedReason;
    return NodeFinding.shouldBeGone(
      reason == null || reason.isEmpty ? 'This is the object that should be gone.' : 'Expected to be gone: $reason',
    );
  }
}

/// A static variable lives as long as the app does, and so does what holds it.
class StaticHolderInspector implements NodeInspector {
  const StaticHolderInspector();

  @override
  NodeFinding? inspect(InspectedNode node) =>
      node.node.kind == TraceNodeKind.staticHolder ? const NodeFinding.inUse('A static variable lives as long as the app.') : null;
}

/// What Dart's own event loop keeps: a pending timer is in it by design.
class RuntimeInternalsInspector implements NodeInspector {
  const RuntimeInternalsInspector();

  @override
  NodeFinding? inspect(InspectedNode node) {
    if (node.node.kind != TraceNodeKind.instance) return null;
    if (node.node.library == 'dart:isolate') return const NodeFinding.inUse('The Dart event loop owns it: it keeps every pending timer.');
    return null;
  }
}

/// The objects an app has one of for as long as it runs.
class FrameworkSingletonInspector implements NodeInspector {
  const FrameworkSingletonInspector();

  static const Set<String> _classes = {
    'PlatformDispatcher',
    'BuildOwner',
    'PipelineOwner',
    'FocusManager',
    'RenderView',
    'RestorationManager',
    'ImageCache',
    'PointerRouter',
    'GestureArenaManager',
    'HardwareKeyboard',
    'KeyEventManager',
  };

  @override
  NodeFinding? inspect(InspectedNode node) {
    final traceNode = node.node;
    if (traceNode.kind != TraceNodeKind.instance) return null;
    final library = traceNode.library ?? '';
    // `package:flutter/`, not `package:flutter`: an app called `flutter_application_1` is not the framework.
    final fromFlutter =
        library.startsWith('package:flutter/') ||
        library.startsWith('package:flutter_test/') ||
        library.startsWith('package:integration_test/') ||
        library.startsWith('dart:ui');
    if (!fromFlutter) return null;
    if (_classes.contains(traceNode.name) || traceNode.name.endsWith('Binding')) {
      return const NodeFinding.inUse('The app keeps one of these for as long as it runs.');
    }
    return null;
  }
}

/// Another watched object that is retained: a leak can pass through one, and what
/// holds it should be gone too.
class OtherWatchedObjectInspector implements NodeInspector {
  const OtherWatchedObjectInspector();

  @override
  NodeFinding? inspect(InspectedNode node) {
    final reason = node.alsoExpectedGone;
    if (node.isLeakedObject || reason == null) return null;
    return NodeFinding.shouldBeGone('Also expected to be gone: $reason');
  }
}

/// Says that an object is gone or alive by one of its fields, when the class that
/// declares it is one the object belongs to.
class _FieldInspector implements NodeInspector {
  const _FieldInspector({
    required this.declaringClass,
    required this.field,
    required this.goneWhen,
    required this.goneReason,
    required this.liveReason,
  });

  final String declaringClass;
  final String field;

  /// What the field holds when the object is gone.
  final String goneWhen;

  final String goneReason;
  final String liveReason;

  @override
  NodeFinding? inspect(InspectedNode node) {
    final facts = node.facts;
    if (facts == null || !facts.declares(declaringClass)) return null;
    final value = facts.valueOf(declaringClass, field);
    if (value == null) return null;
    return value == goneWhen ? NodeFinding.shouldBeGone(goneReason) : NodeFinding.inUse(liveReason);
  }
}

/// A `ChangeNotifier` that has not been disposed is alive; one that was is not.
class ChangeNotifierInspector extends _FieldInspector {
  const ChangeNotifierInspector()
    : super(
        declaringClass: 'ChangeNotifier',
        field: '_debugDisposed',
        goneWhen: 'true',
        goneReason: 'A ChangeNotifier that was disposed.',
        liveReason: 'A ChangeNotifier that has not been disposed.',
      );
}

/// A `State` that has an element is on screen; one that has none was disposed.
class StateInspector extends _FieldInspector {
  const StateInspector()
    : super(
        declaringClass: 'State',
        field: '_element',
        goneWhen: 'null',
        goneReason: 'A State that was disposed.',
        liveReason: 'A State that is on screen.',
      );
}

/// An `Element` that still has its widget is in the tree.
class ElementInspector extends _FieldInspector {
  const ElementInspector()
    : super(
        declaringClass: 'Element',
        field: '_widget',
        goneWhen: 'null',
        goneReason: 'An Element that was removed from the tree.',
        liveReason: 'An Element that is in the tree.',
      );
}

/// A `Route` that has no navigator was let go of.
class RouteInspector extends _FieldInspector {
  const RouteInspector()
    : super(
        declaringClass: 'Route',
        field: '_navigator',
        goneWhen: 'null',
        goneReason: 'A Route that its Navigator let go of.',
        liveReason: 'A Route that is on a Navigator.',
      );
}

/// An `AnimationController` that has no ticker was disposed.
class AnimationControllerInspector extends _FieldInspector {
  const AnimationControllerInspector()
    : super(
        declaringClass: 'AnimationController',
        field: '_ticker',
        goneWhen: 'null',
        goneReason: 'An AnimationController that was disposed.',
        liveReason: 'An AnimationController that has not been disposed.',
      );
}

/// A `RenderObject` that was disposed.
class RenderObjectInspector extends _FieldInspector {
  const RenderObjectInspector()
    : super(
        declaringClass: 'RenderObject',
        field: '_debugDisposed',
        goneWhen: 'true',
        goneReason: 'A RenderObject that was disposed.',
        liveReason: 'A RenderObject that has not been disposed.',
      );
}
