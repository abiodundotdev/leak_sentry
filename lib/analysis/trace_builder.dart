import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/analysis/node_status.dart';
import 'package:leak_sentry/analysis/object_inspectors.dart';
import 'package:leak_sentry/models/field_facts.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/retaining_element.dart';

/// Turns what the VM says holds a leaked object alive into a [LeakTrace]: the
/// steps in the order a developer reads them, each named as it is written in
/// code, and each saying how it holds the next.
///
/// The VM lists the path from the leaked object to the root, and a closure holds
/// a context that holds what it captured; the trace goes from the root to the
/// leaked object and a closure holds what it captured directly.
class TraceBuilder {
  TraceBuilder._();

  /// The trace of [path], with what each step is, which references are likely
  /// causes, and the fingerprint of the leak.
  ///
  /// Every step is shown to the inspectors. The object that leaked is always a step
  /// that should be gone, and what that means for the others follows:
  ///
  /// - every step above the last one that is in use is in use too, because what
  ///   holds something that is in use is in use;
  /// - every step below the first one that should be gone should be gone too,
  ///   because what a leak holds is leaked;
  /// - what is left, LeakSentry cannot tell, and its references are the likely causes.
  ///
  /// [leakedReason] is why the leaked object was expected to be gone.
  /// [alsoExpectedGone] gives, by identity hash, the reason of every other object
  /// that is watched and retained. [facts] is what the VM said about the fields of
  /// the steps it was asked about, by object id.
  ///
  /// The fingerprint is made from what the inspectors that need only the path say,
  /// never from [facts]: a question the VM did not answer must not turn one leak into
  /// two.
  static LeakTrace? build(
    RetainingPathInfo path, {
    String? leakedReason,
    Map<int, String> alsoExpectedGone = const {},
    Map<String, FieldFacts> facts = const {},
    List<NodeInspector> structural = structuralInspectors,
    List<NodeInspector> fields = fieldInspectors,
  }) {
    final base = structure(path);
    if (base == null) return null;

    List<TraceNode> inspect(List<NodeInspector> inspectors, Map<String, FieldFacts> facts) =>
        _inspect(base.nodes, inspectors, leakedReason: leakedReason, alsoExpectedGone: alsoExpectedGone, facts: facts);

    final structuralNodes = inspect(structural, const {});
    final fingerprint = _fingerprintOf(structuralNodes);
    final nodes = facts.isEmpty ? structuralNodes : inspect([...structural, ...fields], facts);
    return LeakTrace(nodes: nodes, gcRootType: base.gcRootType, hiddenSteps: base.hiddenSteps, fingerprint: fingerprint);
  }

  /// The ids of the steps worth asking the VM about the fields of, nearest the leaked
  /// object first, and no more than [limit]: an object that may be a `State`, an
  /// `Element`, a `Route`, a `ChangeNotifier`. A class, a list, a closure, the leaked
  /// object, and what Dart itself owns say what they are without being asked.
  static List<String> objectsToInspect(LeakTrace trace, {int limit = 40}) {
    final ids = <String>[];
    for (final node in trace.nodes.reversed.skip(1)) {
      final id = node.objectId;
      if (id == null || node.kind != TraceNodeKind.instance) continue;
      if ((node.library ?? '').startsWith('dart:')) continue;
      ids.add(id);
      if (ids.length == limit) break;
    }
    return ids;
  }

  static List<TraceNode> _inspect(
    List<TraceNode> nodes,
    List<NodeInspector> inspectors, {
    required String? leakedReason,
    required Map<int, String> alsoExpectedGone,
    required Map<String, FieldFacts> facts,
  }) {
    final last = nodes.length - 1;
    final statuses = <_Resolved>[];
    for (var i = 0; i < nodes.length; i++) {
      final inspected = InspectedNode(
        node: nodes[i],
        isLeakedObject: i == last,
        facts: nodes[i].objectId == null ? null : facts[nodes[i].objectId],
        leakedReason: i == last ? leakedReason : null,
        alsoExpectedGone: nodes[i].identityHash == null ? null : alsoExpectedGone[nodes[i].identityHash],
      );
      final findings = <NodeFinding>[];
      for (final inspector in inspectors) {
        final finding = inspector.inspect(inspected);
        if (finding != null) findings.add(finding);
      }
      statuses.add(_resolve(findings, mustBeGone: i == last));
    }

    // A leak trace ends where the leak is.
    switch (statuses[last].status) {
      case NodeStatus.shouldBeGone:
        break;
      case NodeStatus.unclear:
        statuses[last] = const _Resolved(NodeStatus.shouldBeGone, 'This is the object that should be gone.');
      case NodeStatus.inUse:
        statuses[last] = _Resolved(NodeStatus.shouldBeGone, 'This is the object that should be gone. Conflicts with ${statuses[last].reason}');
    }

    var lastInUse = -1;
    var firstGone = last;
    for (var i = 0; i < statuses.length; i++) {
      if (statuses[i].status == NodeStatus.inUse) {
        lastInUse = i;
        // So that the first step that should be gone never comes before the last one in use.
        firstGone = last;
      } else if (statuses[i].status == NodeStatus.shouldBeGone && firstGone == last) {
        firstGone = i;
      }
    }

    // What holds something that is in use is in use.
    for (var i = 0; i < lastInUse; i++) {
      final next = [for (var j = i + 1; j <= lastInUse; j++) j].firstWhere((j) => statuses[j].status == NodeStatus.inUse);
      final below = '${nodes[next].name} below it is in use';
      final current = statuses[i];
      statuses[i] = switch (current.status) {
        NodeStatus.unclear => _Resolved(NodeStatus.inUse, '$below.'),
        NodeStatus.inUse => _Resolved(NodeStatus.inUse, '$below, and ${_lowerFirst(current.reason)}'),
        NodeStatus.shouldBeGone => _Resolved(NodeStatus.inUse, '$below. Conflicts with ${_lowerFirst(current.reason)}'),
      };
    }

    // What a leak holds is leaked.
    for (var i = last - 1; i > firstGone; i--) {
      final previous = [for (var j = i - 1; j >= firstGone; j--) j].firstWhere((j) => statuses[j].status == NodeStatus.shouldBeGone);
      final above = '${nodes[previous].name} above it should be gone';
      final current = statuses[i];
      statuses[i] = switch (current.status) {
        NodeStatus.unclear => _Resolved(NodeStatus.shouldBeGone, '$above.'),
        NodeStatus.shouldBeGone => _Resolved(NodeStatus.shouldBeGone, '$above, and ${_lowerFirst(current.reason)}'),
        // Cannot be: the first step that should be gone is after the last one in use.
        NodeStatus.inUse => current,
      };
    }

    return [
      for (var i = 0; i < nodes.length; i++)
        nodes[i].copyWith(
          status: statuses[i].status,
          note: statuses[i].reason.isEmpty ? null : statuses[i].reason,
          reference: nodes[i].reference?.withSuspect(_isSuspect(statuses, i)),
        ),
    ];
  }

  /// Whether the reference of step [index] is a likely cause: it is when LeakSentry
  /// cannot tell what its step is, or when its step is in use and what it holds is
  /// not. The last step is the leaked object, which is never in use, so the step
  /// before it always qualifies. A step that should be gone is already past the cause.
  static bool _isSuspect(List<_Resolved> statuses, int index) => switch (statuses[index].status) {
    NodeStatus.unclear => true,
    NodeStatus.inUse => statuses[index + 1].status != NodeStatus.inUse,
    NodeStatus.shouldBeGone => false,
  };

  /// The inspectors' findings for one step, resolved into one status. When they
  /// disagree, a step that is in use stays so, unless it is the leaked object, which
  /// is by definition one that should be gone.
  static _Resolved _resolve(List<NodeFinding> findings, {required bool mustBeGone}) {
    final inUse = [for (final finding in findings) if (finding.status == NodeStatus.inUse) finding.reason];
    final gone = [for (final finding in findings) if (finding.status == NodeStatus.shouldBeGone) finding.reason];
    var status = NodeStatus.unclear;
    var reason = '';
    if (inUse.isNotEmpty) {
      status = NodeStatus.inUse;
      reason = inUse.join(' ');
    }
    if (gone.isNotEmpty) {
      final goneReason = gone.join(' ');
      if (status == NodeStatus.inUse) {
        if (mustBeGone) {
          status = NodeStatus.shouldBeGone;
          reason = '$goneReason Conflicts with ${_lowerFirst(reason)}';
        } else {
          reason = '$reason Conflicts with ${_lowerFirst(goneReason)}';
        }
      } else {
        status = NodeStatus.shouldBeGone;
        reason = goneReason;
      }
    }
    return _Resolved(status, reason);
  }

  /// What identifies the bug: the likely causes, as the class that holds each and the
  /// reference it is held by, without an index, a key or an address.
  static String _fingerprintOf(List<TraceNode> nodes) {
    final causes = [
      for (final node in nodes)
        if (node.reference != null && node.reference!.isSuspect) '${node.library ?? ''}:${node.name}:${node.reference!.genericName}',
    ];
    if (causes.isNotEmpty) return causes.join('|');
    final leaked = nodes.last;
    return 'leaked:${leaked.library ?? ''}:${leaked.name}';
  }

  static String _lowerFirst(String text) => text.isEmpty ? text : '${text[0].toLowerCase()}${text.substring(1)}';

  /// The trace of [path], or null if it has no elements to build one from.
  static LeakTrace? structure(RetainingPathInfo path) {
    final raw = path.elements;
    if (raw.isEmpty) return null;
    final nodes = <TraceNode>[];
    // From the root to the leaked object. `raw[i]` holds `raw[i - 1]`.
    for (var i = raw.length - 1; i >= 0; i--) {
      final element = raw[i];
      final held = i > 0 ? raw[i - 1] : null;
      switch (element.kind) {
        case RetainingElementKind.context:
          // A closure takes the context it holds in with it (below), so one that
          // is reached here is held by something else: show it as what it is.
          nodes.add(
            TraceNode(
              kind: TraceNodeKind.closure,
              name: 'captured variables',
              reference: held == null ? null : _captured,
            ),
          );
        case RetainingElementKind.closure:
          if (held != null && held.kind == RetainingElementKind.context) {
            nodes.add(_closureNode(element, _captured));
            i--; // the context is folded into the closure
          } else {
            nodes.add(_closureNode(element, held == null ? null : _receiver));
          }
        default:
          nodes.add(_node(element, isLast: held == null));
      }
    }
    return LeakTrace(nodes: nodes, gcRootType: path.gcRootType, hiddenSteps: path.hiddenSteps);
  }

  static const TraceReference _receiver = TraceReference(
    kind: TraceReferenceKind.receiver,
    name: 'receiver',
    genericName: '<receiver>',
  );

  static const TraceReference _captured = TraceReference(
    kind: TraceReferenceKind.capturedVariable,
    name: 'captured variable',
    genericName: '<captured>',
  );

  static TraceNode _closureNode(RetainingElement element, TraceReference? reference) => TraceNode(
    kind: TraceNodeKind.closure,
    name: element.function ?? 'closure',
    library: element.libraryUri,
    declaredAt: element.declaredAt,
    identityHash: element.identityHash,
    objectId: element.objectId,
    reference: reference,
  );

  static TraceNode _node(RetainingElement element, {required bool isLast}) {
    switch (element.kind) {
      case RetainingElementKind.staticField:
        final field = element.field ?? '?';
        return TraceNode(
          kind: TraceNodeKind.staticHolder,
          name: element.className ?? _fileName(element.libraryUri),
          library: element.libraryUri,
          declaredAt: element.declaredAt,
          reference: TraceReference(
            kind: TraceReferenceKind.staticVariable,
            name: '.$field',
            genericName: field,
          ),
        );
      case RetainingElementKind.list:
        final index = element.index;
        return TraceNode(
          kind: TraceNodeKind.list,
          name: element.className ?? 'List',
          library: element.libraryUri,
          declaredAt: element.declaredAt,
          identityHash: element.identityHash,
          objectId: element.objectId,
          reference: isLast
              ? null
              : TraceReference(
                  kind: TraceReferenceKind.listSlot,
                  name: index == null ? '[?]' : '[$index]',
                  genericName: '[x]',
                ),
        );
      case RetainingElementKind.map:
        final key = element.mapKey;
        return TraceNode(
          kind: TraceNodeKind.map,
          name: element.className ?? 'Map',
          library: element.libraryUri,
          declaredAt: element.declaredAt,
          identityHash: element.identityHash,
          objectId: element.objectId,
          reference: isLast
              ? null
              : TraceReference(
                  kind: TraceReferenceKind.mapEntry,
                  name: key == null ? '[?]' : (element.mapKeyIsText ? "['$key']" : '[$key]'),
                  genericName: '{key}',
                ),
        );
      case RetainingElementKind.instance:
      case RetainingElementKind.other:
      case RetainingElementKind.closure:
      case RetainingElementKind.context:
        final field = element.field;
        return TraceNode(
          kind: TraceNodeKind.instance,
          name: element.className ?? 'object',
          library: element.libraryUri,
          declaredAt: element.declaredAt,
          identityHash: element.identityHash,
          objectId: element.objectId,
          reference: isLast
              ? null
              : TraceReference(
                  kind: TraceReferenceKind.field,
                  name: field == null ? '.?' : '.$field',
                  genericName: field ?? '<unknown>',
                ),
        );
    }
  }

  /// The name of the file a library URI points at: `main.dart`.
  static String _fileName(String? uri) {
    if (uri == null) return 'library';
    final slash = uri.lastIndexOf('/');
    return slash < 0 ? uri : uri.substring(slash + 1);
  }
}

/// A step's status and why.
class _Resolved {
  const _Resolved(this.status, this.reason);

  final NodeStatus status;
  final String reason;
}
