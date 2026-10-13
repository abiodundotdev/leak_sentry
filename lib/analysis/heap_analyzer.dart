import 'dart:async';

import 'package:leak_sentry/analysis/heap_analysis.dart';
import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/analysis/trace_builder.dart';
import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/core/leak_sentry_config.dart';
import 'package:leak_sentry/core/leak_sentry_log.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/field_facts.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/leak_sentry_stats.dart';
import 'package:leak_sentry/models/retaining_element.dart';
import 'package:leak_sentry/models/vm_bridge.dart';
import 'package:leak_sentry/object_watcher/keyed_weak_reference.dart';
import 'package:leak_sentry/utils/creation_site_util.dart';

/// Called when the analysis reaches a new [step]. The analysis waits for the
/// returned future, so a listener can hold it up.
typedef AnalysisProgressListener = FutureOr<void> Function(AnalysisStep step, double progressPercent);

/// Analyzes a heap dump.
abstract interface class HeapAnalyzer {
  /// Never throws: a failure is returned as a [HeapAnalysisFailure].
  Future<HeapAnalysis> analyze(RetainedObjectsDump dump, {AnalysisProgressListener? onProgress});
}

/// Analyzes a [RetainedObjectsDump] by asking the VM service for the retaining
/// path of each distinct retained object.
///
/// Objects that leak for the same reason are one leak: they are grouped by type,
/// description and creation site (or, when none is known, the place the object
/// was handed to the watcher), and only the first of each group costs a
/// lookup. A lookup walks the whole heap inside the VM and pauses the app, so
/// 200 leaked list-item notifiers cost one pause, not 200.
///
/// Once the paths are known, each is worked out into a [LeakTrace]: what each step
/// of it is, and which references are the likely causes. That takes a look at the
/// fields of the objects on the path nearest the leak, to tell a `State` that was
/// disposed from one that is on screen.
class RetainedSetHeapAnalyzer implements HeapAnalyzer {
  RetainedSetHeapAnalyzer({
    required VmBridge vm,
    required LeakSentryConfig Function() config,
    required LeakSentryStats stats,
  }) : _vm = vm,
       _config = config,
       _stats = stats;

  final VmBridge _vm;
  final LeakSentryConfig Function() _config;
  final LeakSentryStats _stats;

  /// The most objects of one path whose fields are looked at. A path is cut at 100
  /// steps, and only the ones nearest the leak say what the leak is.
  static const int _maxFieldReads = 40;

  @override
  Future<HeapAnalysis> analyze(RetainedObjectsDump dump, {AnalysisProgressListener? onProgress}) async {
    final stopwatch = Stopwatch()..start();
    try {
      final found = await _findLeaks(dump, onProgress);
      return HeapAnalysisSuccess(
        dump: dump,
        analysisDuration: stopwatch.elapsed,
        leaks: found.leaks,
        unreachableObjectCount: found.unreachableObjectCount,
      );
    } catch (error, stackTrace) {
      return HeapAnalysisFailure(
        dump: dump,
        analysisDuration: stopwatch.elapsed,
        exception: error,
        stackTrace: stackTrace,
      );
    } finally {
      _stats.analyses++;
      _stats.analysisMicros += stopwatch.elapsedMicroseconds;
    }
  }

  Future<({List<LeakReport> leaks, int unreachableObjectCount})> _findLeaks(
    RetainedObjectsDump dump,
    AnalysisProgressListener? onProgress,
  ) async {
    await _report(onProgress, AnalysisStep.findingRetainedObjects);
    final groups = _groupLeaks(dump.objects);

    await _report(onProgress, AnalysisStep.findingPathsToRetainedObjects);
    final config = _config();
    final isolateId = dump.isolateId;
    // The ids the VM hands out keep what they name alive, so each lookup has a zone of its own for
    // them, which is emptied once the leak has been worked out: the analysis must not go on holding
    // the objects on the paths it looked at.
    final openZones = <String>{};
    try {
      return await _lookUpAndTrace(dump, groups, config, isolateId, openZones, onProgress);
    } finally {
      for (final zone in [...openZones]) {
        await _closeIdZone(isolateId!, zone, openZones);
      }
    }
  }

  Future<({List<LeakReport> leaks, int unreachableObjectCount})> _lookUpAndTrace(
    RetainedObjectsDump dump,
    List<_LeakGroup> groups,
    LeakSentryConfig config,
    String? isolateId,
    Set<String> openZones,
    AnalysisProgressListener? onProgress,
  ) async {
    var lookups = 0;
    var unreachableObjectCount = 0;
    final looked = <_LookedUp>[];
    for (final group in groups) {
      // An object collected since the dump is not a leak anymore.
      final alive = [
        for (final object in group.objects)
          if (!object.isCollected) object,
      ];
      unreachableObjectCount += group.objects.length - alive.length;
      if (alive.isEmpty) continue;
      final representative = alive.first;
      String? objectId;
      String? idZoneId;
      RetainingPathInfo? retainingPath;
      RetainingPathGap? pathGap;
      if (!config.enableRetainingPathAnalysis) {
        pathGap = RetainingPathGap.disabled;
      } else if (isolateId == null) {
        pathGap = RetainingPathGap.noVmService;
      } else if (lookups >= config.maxRetainingPathLookups) {
        pathGap = RetainingPathGap.lookupLimitReached;
      } else {
        // Asked for only now, and only for the representative of each leak:
        // an id pins the object in the VM until the id falls out of its ring.
        objectId = representative.resolveVmObjectId();
        if (objectId == null) {
          pathGap = RetainingPathGap.objectUnavailable;
        } else {
          lookups++;
          idZoneId = await _openIdZone(isolateId, openZones);
          retainingPath = await _lookUpRetainingPath(isolateId, objectId, idZoneId);
          if (retainingPath == null) pathGap = RetainingPathGap.lookupFailed;
        }
      }
      _stats.duplicatesSkipped += alive.length - 1;
      // The VM answers a path of no elements, and a root type left over from
      // its search, for an object nothing refers to anymore.
      if (retainingPath != null && retainingPath.hops.isEmpty) {
        unreachableObjectCount += alive.length;
        if (idZoneId != null) await _closeIdZone(isolateId!, idZoneId, openZones);
        continue;
      }
      if (retainingPath == null && idZoneId != null) {
        await _closeIdZone(isolateId!, idZoneId, openZones);
        idZoneId = null;
      }
      looked.add(
        _LookedUp(
          group: group,
          representative: representative,
          count: alive.length,
          objectId: objectId,
          idZoneId: idZoneId,
          retainingPath: retainingPath,
          pathGap: pathGap,
        ),
      );
    }

    await _report(onProgress, AnalysisStep.buildingLeakTraces);
    // What else is expected to be gone: a leak can pass through another object that
    // is watched and retained, and what holds that one is where the leak starts.
    final expectedGone = {
      for (final object in dump.objects)
        if (!object.isCollected) object.identityHash: object.description,
    };
    final reports = <LeakReport>[];
    for (final item in looked) {
      final path = item.retainingPath;
      final representative = item.representative;
      final LeakTrace? trace;
      if (path == null || isolateId == null) {
        trace = null;
      } else {
        try {
          trace = await _traceOf(isolateId, path, representative.description, expectedGone, item.idZoneId);
        } finally {
          final zone = item.idZoneId;
          if (zone != null) await _closeIdZone(isolateId, zone, openZones);
        }
      }
      reports.add(
        LeakReport(
          type: representative.type,
          reason: representative.description,
          firstObservedAt: representative.watchedAt,
          detectedAt: DateTime.now(),
          confidence: LeakConfidence.retainedAfterGc,
          objectId: item.objectId,
          retainingPath: path,
          trace: trace,
          creationSite: item.group.origin.creationSite,
          watchSite: item.group.origin.watchSite,
          classSite: _classSiteOf(path),
          creationSiteGap: item.group.origin.gap,
          pathGap: item.pathGap,
          signature: item.group.signature,
          occurrenceCount: item.count,
        ),
      );
    }
    return (leaks: reports, unreachableObjectCount: unreachableObjectCount);
  }

  /// The path worked out, or null when that is not possible: a trace is there to
  /// help read the path, so a failure to make one never costs the leak its report.
  Future<LeakTrace?> _traceOf(
    String isolateId,
    RetainingPathInfo path,
    String reason,
    Map<int, String> expectedGone,
    String? idZoneId,
  ) async {
    try {
      final structure = TraceBuilder.structure(path);
      if (structure == null) return null;
      final facts = <String, FieldFacts>{};
      for (final id in TraceBuilder.objectsToInspect(structure, limit: _maxFieldReads)) {
        final read = await _readFields(isolateId, id, idZoneId);
        if (read != null) facts[id] = read;
      }
      return TraceBuilder.build(path, leakedReason: reason, alsoExpectedGone: expectedGone, facts: facts);
    } catch (error, stackTrace) {
      LeakSentryLog.d(() => 'Could not work out the trace of a retaining path', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  /// What the VM says about the fields of one object of a path. A step it cannot
  /// say anything about stays unclear.
  Future<FieldFacts?> _readFields(String isolateId, String objectId, String? idZoneId) async {
    try {
      return await _vm.readFields(isolateId, objectId, idZoneId: idZoneId);
    } catch (error, stackTrace) {
      LeakSentryLog.d(() => 'Could not read the fields of an object on a retaining path', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  /// Opens the zone for the ids of one lookup, or null if the VM has none to give: the lookup is
  /// made all the same, with its ids in the VM's shared ring.
  Future<String?> _openIdZone(String isolateId, Set<String> openZones) async {
    try {
      final zone = await _vm.openIdZone(isolateId);
      if (zone != null) openZones.add(zone);
      return zone;
    } catch (error, stackTrace) {
      LeakSentryLog.d(() => 'Could not open a zone for the ids of a lookup', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  Future<void> _closeIdZone(String isolateId, String zoneId, Set<String> openZones) async {
    openZones.remove(zoneId);
    try {
      await _vm.closeIdZone(isolateId, zoneId);
    } catch (error, stackTrace) {
      LeakSentryLog.d(() => 'Could not empty the zone of the ids of a lookup', error: error, stackTrace: stackTrace);
    }
  }

  Future<RetainingPathInfo?> _lookUpRetainingPath(String isolateId, String objectId, String? idZoneId) async {
    final stopwatch = Stopwatch()..start();
    try {
      return await _vm.retainingPath(isolateId, objectId, idZoneId: idZoneId);
    } finally {
      _stats.retainingPathLookups++;
      _stats.retainingPathMicros += stopwatch.elapsedMicroseconds;
    }
  }

  Future<void> _report(AnalysisProgressListener? onProgress, AnalysisStep step) async {
    await onProgress?.call(step, step.progressPercent);
  }

  List<_LeakGroup> _groupLeaks(List<RetainedObjectSnapshot> objects) {
    final bySignature = <String, _LeakGroup>{};
    for (final object in objects) {
      final origin = _originOf(object);
      // Leaks of one type created at different places are different leaks, and
      // merging them would show only the first one's creation site. The same
      // goes for objects only known by where they were handed to the watcher.
      final siteKey = switch ((origin.creationSite, origin.watchSite)) {
        (final CreationSite created, _) => '|${created.uri}:${created.line}',
        (_, final CreationSite watched) => '|watch:${watched.uri}:${watched.line}',
        _ => '',
      };
      final signature = '${object.type}|${LeakConfidence.retainedAfterGc}|${object.description}$siteKey';
      bySignature.putIfAbsent(signature, () => _LeakGroup(signature, origin)).objects.add(object);
    }
    return bySignature.values.toList(growable: false);
  }

  /// Where [object] came from: the line that created it, else the line that
  /// handed it to the watcher, else why neither is known.
  _Origin _originOf(RetainedObjectSnapshot object) {
    final created = CreationSiteUtil.resolveWithReason(object.creationStack, type: object.type);
    if (created.site != null) return _Origin(creationSite: created.site);
    final watchStack = object.watchStack;
    if (watchStack == null) return _Origin(gap: created.gap);
    final watched = CreationSiteUtil.resolveWithReason(watchStack, type: object.type);
    if (watched.site != null) return _Origin(watchSite: watched.site);
    // A creation stack that was read and held nothing to show says more than a
    // watch stack that held nothing either.
    return _Origin(gap: object.creationStack != null ? created.gap : watched.gap);
  }

  /// Where the class of the leaked object is declared, when the VM said.
  CreationSite? _classSiteOf(RetainingPathInfo? path) {
    final first = path?.elements.firstOrNull;
    if (first == null) return null;
    return switch (first.kind) {
      RetainingElementKind.instance || RetainingElementKind.list || RetainingElementKind.map => first.declaredAt,
      _ => null,
    };
  }
}

/// How a leaked object can be traced back to the code behind it.
class _Origin {
  _Origin({this.creationSite, this.watchSite, this.gap});

  final CreationSite? creationSite;
  final CreationSite? watchSite;
  final CreationSiteGap? gap;
}

class _LeakGroup {
  _LeakGroup(this.signature, this.origin);

  final String signature;
  final _Origin origin;
  final List<RetainedObjectSnapshot> objects = [];
}

/// A group of leaks with the path of its representative, before it is worked out.
class _LookedUp {
  _LookedUp({
    required this.group,
    required this.representative,
    required this.count,
    required this.objectId,
    required this.idZoneId,
    required this.retainingPath,
    required this.pathGap,
  });

  final _LeakGroup group;
  final RetainedObjectSnapshot representative;

  /// How many objects of the group are still alive.
  final int count;

  final String? objectId;

  /// The zone of the ids the lookup of the path handed out, while it is open.
  final String? idZoneId;
  final RetainingPathInfo? retainingPath;
  final RetainingPathGap? pathGap;
}
