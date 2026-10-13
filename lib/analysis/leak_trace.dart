import 'package:leak_sentry/analysis/node_status.dart';
import 'package:leak_sentry/models/creation_site.dart';

/// How one step of a leak's path holds the next one.
enum TraceReferenceKind {
  /// A field of an object: `.pages`.
  field,

  /// A static variable, which is what a path starts at: `.pages`.
  staticVariable,

  /// A slot of a list: `[3]`.
  listSlot,

  /// An entry of a map: `['key']`.
  mapEntry,

  /// A variable a closure captured.
  capturedVariable,

  /// The object a torn-off method is bound to.
  receiver,
}

/// The link from one step of a path to the next.
class TraceReference {
  const TraceReference({
    required this.kind,
    required this.name,
    required this.genericName,
    this.isSuspect = false,
  });

  final TraceReferenceKind kind;

  /// How it is written: `.pages`, `[3]`, `['key']`, `captured variable`, `receiver`.
  final String name;

  /// The same, without anything that changes from one run to the next, so that
  /// the same leak is the same leak every time: `pages`, `[x]`, `{key}`,
  /// `<captured>`, `<receiver>`. Fingerprints are made of these.
  final String genericName;

  /// Whether this is one of the likeliest causes of the leak.
  final bool isSuspect;

  TraceReference withSuspect(bool suspect) =>
      TraceReference(kind: kind, name: name, genericName: genericName, isSuspect: suspect);
}

/// What a step of a path is.
enum TraceNodeKind {
  /// An ordinary object.
  instance,

  /// A list.
  list,

  /// A map.
  map,

  /// A closure, with the variables it captured.
  closure,

  /// What holds a static variable: its class, or the file of a top-level one.
  staticHolder,
}

/// One step of the path from something that lives as long as the app to the
/// leaked object.
class TraceNode {
  const TraceNode({
    required this.kind,
    required this.name,
    this.library,
    this.declaredAt,
    this.identityHash,
    this.objectId,
    this.status,
    this.note,
    this.reference,
  });

  final TraceNodeKind kind;

  /// The class, the closure's function, or what holds the static variable, as a
  /// developer writes it.
  final String name;

  /// The library it comes from, as a URI.
  final String? library;

  /// Where it is declared: the class, the variable, or the closure.
  final CreationSite? declaredAt;

  final int? identityHash;

  /// The id the VM gave the object. It is good for asking about the object only
  /// while the analysis runs: afterwards it may name another object.
  final String? objectId;

  /// What LeakSentry makes of this step, when it has looked.
  final NodeStatus? status;

  /// Why it makes that of it.
  final String? note;

  /// How this step holds the next one. Null for the leaked object, which is last.
  final TraceReference? reference;

  TraceNode copyWith({NodeStatus? status, String? note, TraceReference? reference}) => TraceNode(
    kind: kind,
    name: name,
    library: library,
    declaredAt: declaredAt,
    identityHash: identityHash,
    objectId: objectId,
    status: status ?? this.status,
    note: note ?? this.note,
    reference: reference ?? this.reference,
  );
}

/// The path that holds a leaked object alive, from the GC root to the object.
class LeakTrace {
  const LeakTrace({required this.nodes, required this.gcRootType, this.hiddenSteps = 0, this.fingerprint});

  /// The steps, the one nearest the root first and the leaked object last.
  final List<TraceNode> nodes;

  /// The kind of root the VM found the path from: `user global`, `stack`.
  final String gcRootType;

  /// How many steps the VM left out between the first of [nodes] and the root.
  final int hiddenSteps;

  /// What identifies the bug behind this leak: the same leak found in another scan,
  /// another run or another device has the same one. It is made of the references
  /// that are likely causes, named without anything that changes from one run to the
  /// next. Null until someone has worked out which references those are.
  final String? fingerprint;

  /// The references that are likely causes of the leak, with the step each one is
  /// held by.
  List<({TraceNode node, TraceReference reference})> get suspects => [
    for (final node in nodes)
      if (node.reference != null && node.reference!.isSuspect) (node: node, reference: node.reference!),
  ];

  /// What the leak is called in a list: the first likely cause, as the class that
  /// holds it and the reference it holds it by, `PageRegistry.pages`. Null when
  /// no reference is a likely cause.
  String? get title {
    final first = suspects.firstOrNull;
    if (first == null) return null;
    final reference = first.reference;
    final suffix = switch (reference.kind) {
      TraceReferenceKind.field || TraceReferenceKind.staticVariable => '.${reference.genericName}',
      TraceReferenceKind.listSlot => '[x]',
      TraceReferenceKind.mapEntry => '{key}',
      TraceReferenceKind.capturedVariable => ' (captured)',
      TraceReferenceKind.receiver => ' (receiver)',
    };
    return '${first.node.name}$suffix';
  }

  /// Whether a step of the path is LeakSentry's own code: it is holding on to an
  /// object of the app.
  bool get isInternal => nodes.any((node) => node.library?.startsWith('package:leak_sentry/') ?? false);
}
