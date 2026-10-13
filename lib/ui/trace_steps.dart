import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/format.dart';
import 'package:leak_sentry/ui/widgets/trace_timeline.dart';

/// The steps of [trace] as the timeline draws them. The first reference that is a likely
/// cause is the one to start with. [leakedAt] says, under the leaked object, where it
/// came from: `created at lib/main.dart:196`, with what the place is the place of.
List<TimelineStep> timelineStepsOf(LeakTrace trace, {({String label, CreationSite site})? leakedAt}) {
  var startedWith = false;
  return [
    for (var i = 0; i < trace.nodes.length; i++)
      () {
        final node = trace.nodes[i];
        final reference = node.reference;
        final isFirstSuspect = reference != null && reference.isSuspect && !startedWith;
        if (isFirstSuspect) startedWith = true;
        final isLast = i == trace.nodes.length - 1;
        return TimelineStep(
          title: node.name,
          detail: isLast && leakedAt != null
              ? '${leakedAt.label.toLowerCase()} ${shortLocation(leakedAt.site)}'
              : _detailOf(node),
          status: node.status,
          note: node.note,
          reference: reference == null
              ? null
              : TimelineReference(reference.name, isSuspect: reference.isSuspect, isFirstSuspect: isFirstSuspect),
        );
      }(),
  ];
}

/// What to say under a step's name: where a closure is written, or the library
/// anything else comes from.
String? _detailOf(TraceNode node) {
  if (node.kind == TraceNodeKind.closure) {
    final site = node.declaredAt;
    return site == null ? node.library : LeakSentryCopy.writtenAt(shortLocation(site));
  }
  return node.library;
}
