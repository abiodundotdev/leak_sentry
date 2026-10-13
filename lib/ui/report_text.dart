import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/analysis/node_status.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/format.dart';

/// A leak as plain text, for pasting into a bug report or reading in the
/// console. It starts with where the object was created, because that is where a
/// developer starts.
String buildLeakReport(LeakGroup group, {required DateTime now}) {
  final text = StringBuffer()
    ..writeln(LeakSentryCopy.reportHeading)
    ..writeln(
      [
        group.title,
        countOf(group.count, 'object'),
        LeakSentryCopy.lastSeen(formatAgo(group.lastSeen, now)),
      ].join(' · '),
    );
  if (group.cause != null) text.writeln(LeakSentryCopy.holds(describeTypes(group.leakedTypes)));
  if (group.isInternal) text.writeln(LeakSentryCopy.tagInternal);
  final instances = group.instances;
  for (var i = 0; i < instances.length; i++) {
    final instance = instances[i];
    text.writeln();
    if (instances.length > 1) {
      text.writeln(LeakSentryCopy.reportInstance(i + 1, instances.length, instance.leakedType, instance.count));
    }
    _writeOrigin(text, group, instance);
    if (group.kind == LeakKind.resource) {
      _writeAcquisition(text, instance);
    } else {
      _writePath(text, instance);
    }
  }
  return text.toString().trimRight();
}

void _writeOrigin(StringBuffer text, LeakGroup group, LeakInstance instance) {
  final created = instance.creationSite;
  final watched = instance.watchSite;
  if (created != null) {
    final label = group.kind == LeakKind.resource ? LeakSentryCopy.acquiredAt : LeakSentryCopy.createdAt;
    _writeSite(text, label, created);
  } else if (watched != null) {
    _writeSite(text, LeakSentryCopy.watchedAt, watched);
  } else {
    final gap = instance.creationSiteGap;
    text.writeln(
      LeakSentryCopy.reportCreationUnknown(gap == null ? LeakSentryCopy.creationUnknownNoReason : LeakSentryCopy.creationGap(gap)),
    );
    final declared = instance.classSite;
    if (declared != null) _writeSite(text, LeakSentryCopy.classDeclaredAt, declared);
  }
}

void _writeSite(StringBuffer text, String label, CreationSite site) {
  text.writeln('$label: ${fullLocation(site)}');
  final member = site.member;
  if (member != null) text.writeln('  $member');
}

void _writeAcquisition(StringBuffer text, LeakInstance instance) {
  final stack = instance.acquiredAt;
  if (stack == null) return;
  final lines = stack.toString().split('\n').where((line) => line.trim().isNotEmpty).take(10);
  text
    ..writeln(LeakSentryCopy.reportAcquisitionStack)
    ..writeAll(lines.map((line) => '  ${line.trim()}\n'));
}

void _writePath(StringBuffer text, LeakInstance instance) {
  final trace = instance.trace;
  if (trace == null) {
    final gap = instance.pathGap;
    text.writeln(LeakSentryCopy.reportPathUnknown(gap == null ? LeakSentryCopy.pathUnknown : LeakSentryCopy.pathGap(gap)));
    return;
  }
  text
    ..writeln(LeakSentryCopy.reportPath)
    ..writeAll(describeTrace(trace).map((line) => '  $line\n'));
}

/// The path of [trace] as lines of text: what it starts at, then each step with
/// its reference, its status, whether the reference is a likely cause, and, under
/// it, why LeakSentry thinks what it does of the step.
List<String> describeTrace(LeakTrace trace) => [
  LeakSentryCopy.startsAt(trace.gcRootType),
  if (trace.hiddenSteps > 0) '(${LeakSentryCopy.moreSteps(trace.hiddenSteps)})',
  for (var i = 0; i < trace.nodes.length; i++) ..._describeStep(trace.nodes[i], i, isLast: i == trace.nodes.length - 1),
];

List<String> _describeStep(TraceNode node, int index, {required bool isLast}) {
  final reference = node.reference;
  final status = node.status;
  final note = node.note;
  return [
    [
      '${index + 1}. ${node.name}',
      if (reference != null) reference.name,
      if (status != null) '[${_statusWord(status)}]',
      if (reference != null && reference.isSuspect) '<- ${LeakSentryCopy.reportLikelyCause}',
      if (isLast) '(${LeakSentryCopy.reportLeakedObject})',
    ].join(' '),
    if (note != null && note.isNotEmpty) '   $note',
  ];
}

String _statusWord(NodeStatus status) => switch (status) {
  NodeStatus.inUse => LeakSentryCopy.statusInUse.toLowerCase(),
  NodeStatus.shouldBeGone => LeakSentryCopy.statusShouldBeGone.toLowerCase(),
  NodeStatus.unclear => LeakSentryCopy.statusUnclear.toLowerCase(),
};
