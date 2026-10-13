import 'package:leak_sentry/analysis/heap_analysis.dart';
import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/object_watcher/keyed_weak_reference.dart';

import 'leak_fixtures.dart';

/// Classes whose names the screens show.
class PageThreeState {}

class PageFourState {}

class AppSettings {}

/// A leak report, as the analysis makes one.
LeakReport leakReport({
  Type type = PageThreeState,
  String? reason,
  String? signature,
  int count = 1,
  CreationSite? created = initStateSite,
  CreationSite? watched,
  CreationSite? declared,
  CreationSiteGap? gap,
  RetainingPathInfo? path,
  RetainingPathGap? pathGap,
  LeakTrace? trace,
  LeakConfidence confidence = LeakConfidence.retainedAfterGc,
  StackTrace? acquiredAt,
}) {
  final why = reason ?? '$type received State#dispose() callback';
  return LeakReport(
    type: type,
    reason: why,
    firstObservedAt: DateTime(2026),
    detectedAt: DateTime(2026),
    confidence: confidence,
    signature: signature ?? '$type|$why|${created?.line}|${watched?.line}',
    occurrenceCount: count,
    creationSite: created,
    watchSite: watched,
    classSite: declared,
    creationSiteGap: gap,
    retainingPath: path,
    trace: trace,
    pathGap: pathGap,
    acquiredAt: acquiredAt,
  );
}

RetainedObjectsDump _dump(int held) => RetainedObjectsDump(
  objects: [
    for (var i = 0; i < held; i++)
      RetainedObjectSnapshot(
        key: 'k$i',
        description: 'd',
        type: PageThreeState,
        identityHash: i,
        watchUptime: Duration.zero,
        retainedUptime: const Duration(seconds: 5),
        watchedAt: DateTime(2026),
      ),
  ],
  dumpUptime: const Duration(seconds: 6),
  isolateId: 'isolates/1',
);

/// A whole scan, as the engine's events tell it: the heap is dumped, and the
/// analysis finds [leaks].
void runScan(LeakCatalog catalog, String id, List<LeakReport> leaks, {int held = 3, int released = 0, String trigger = '3 retained objects, app is visible'}) {
  catalog.onEvent(DumpingHeapEvent(id));
  catalog.onEvent(HeapDumpEvent(id, dump: _dump(held), duration: const Duration(milliseconds: 20), reason: trigger));
  catalog.onEvent(
    HeapAnalysisSucceededEvent(
      id,
      heapAnalysis: HeapAnalysisSuccess(
        dump: _dump(held),
        analysisDuration: const Duration(milliseconds: 30),
        leaks: leaks,
        unreachableObjectCount: released,
      ),
      newLeakSignatures: const {},
    ),
  );
}

/// A scan that has started and not finished.
void startScan(LeakCatalog catalog, String id, {int held = 3}) {
  catalog.onEvent(HeapDumpEvent(id, dump: _dump(held), duration: Duration.zero, reason: 'user request'));
}
