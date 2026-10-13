import 'package:flutter/foundation.dart';
import 'package:leak_sentry/analysis/heap_analysis.dart';
import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/analysis/trace_builder.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/leak_sentry_internal.dart';

/// What kind of leak a group is.
enum LeakKind {
  /// An object that was expected to be garbage collected and wasn't.
  retained,

  /// A resource that was garbage collected without being closed.
  resource,
}

/// One kind of leak as one report signature found it: the same type, reason
/// and creation site. A copy taken when the leak was found, never a live view of
/// the report, because the report keeps changing after it is found (the hub adds
/// the count of every repeat to the first report).
///
/// It holds names and numbers, never the leaked object, so the catalog can't be
/// what keeps a leak alive.
class LeakInstance {
  const LeakInstance({
    required this.signature,
    required this.leakedType,
    required this.count,
    required this.firstSeen,
    required this.lastSeen,
    this.creationSite,
    this.watchSite,
    this.classSite,
    this.creationSiteGap,
    this.acquiredAt,
    this.retainingPath,
    this.trace,
    this.pathGap,
  });

  /// `LeakReport.signature`.
  final String signature;

  /// The type of what leaked, as text.
  final String leakedType;

  /// How many objects, over every scan that found this.
  final int count;

  final DateTime firstSeen;
  final DateTime lastSeen;

  /// See `LeakReport.creationSite`.
  final CreationSite? creationSite;

  /// See `LeakReport.watchSite`.
  final CreationSite? watchSite;

  /// See `LeakReport.classSite`.
  final CreationSite? classSite;

  /// See `LeakReport.creationSiteGap`.
  final CreationSiteGap? creationSiteGap;

  /// See `LeakReport.acquiredAt`. Only a resource leak has one.
  final StackTrace? acquiredAt;

  /// The retaining path of the latest scan that had one.
  final RetainingPathInfo? retainingPath;

  /// [retainingPath] as steps with a status each and the likely causes marked: the
  /// one of the latest scan that had a path. A report that came with a path and no
  /// trace gets the steps and nothing more: no status, no likely cause.
  final LeakTrace? trace;

  /// Why there is no [retainingPath].
  final RetainingPathGap? pathGap;

  static LeakTrace? _traceOf(LeakReport report) {
    final path = report.retainingPath;
    return report.trace ?? (path == null ? null : TraceBuilder.structure(path));
  }

  /// This, with what another scan found of the same signature added.
  LeakInstance foundAgain(LeakReport report, DateTime now) {
    final path = report.retainingPath ?? retainingPath;
    return LeakInstance(
      signature: signature,
      leakedType: leakedType,
      count: count + report.occurrenceCount,
      firstSeen: firstSeen,
      lastSeen: now,
      creationSite: creationSite,
      watchSite: watchSite,
      classSite: report.classSite ?? classSite,
      creationSiteGap: creationSiteGap,
      acquiredAt: acquiredAt,
      retainingPath: path,
      trace: _traceOf(report) ?? trace,
      pathGap: path == null ? (report.pathGap ?? pathGap) : null,
    );
  }

  /// The first sighting of [report].
  factory LeakInstance.firstFound(LeakReport report, DateTime now) => LeakInstance(
    signature: report.signature,
    leakedType: '${report.type}',
    count: report.occurrenceCount,
    firstSeen: now,
    lastSeen: now,
    creationSite: report.creationSite,
    watchSite: report.watchSite,
    classSite: report.classSite,
    creationSiteGap: report.creationSiteGap,
    acquiredAt: report.acquiredAt,
    retainingPath: report.retainingPath,
    trace: _traceOf(report),
    pathGap: report.retainingPath == null ? report.pathGap : null,
  );
}

/// One distinct leak: what the Leaks screen shows as one row.
class LeakGroup {
  const LeakGroup({
    required this.id,
    required this.kind,
    required this.leakedType,
    required this.reason,
    required this.instances,
    required this.firstSeen,
    required this.lastSeen,
    required this.isUnread,
  });

  /// Stable for as long as the catalog is: what a screen refers to a leak by.
  final String id;

  final LeakKind kind;

  /// The type of the leaked object, as text.
  final String leakedType;

  /// Why the object was expected to be gone, or the label of the resource.
  final String reason;

  /// One per report signature, in the order they were found. At least one.
  final List<LeakInstance> instances;

  final DateTime firstSeen;
  final DateTime lastSeen;

  /// Whether the leak is new, and its details haven't been opened since.
  final bool isUnread;

  /// How many objects, over every scan and every instance.
  int get count => instances.fold(0, (total, instance) => total + instance.count);

  /// The distinct types of what leaked, in the order they were found. Leaks held
  /// the same way are one leak, whatever they are.
  List<String> get leakedTypes => [
    ...{for (final instance in instances) instance.leakedType},
  ];

  /// The likely cause of the leak, as the freshest trace names it: the class that
  /// holds the leak and how, `PageRegistry.pages`. Null for a resource, and when no
  /// trace says.
  String? get cause {
    if (kind == LeakKind.resource) return null;
    String? title;
    DateTime? seenAt;
    for (final instance in instances) {
      final candidate = instance.trace?.title;
      if (candidate == null) continue;
      if (seenAt == null || instance.lastSeen.isAfter(seenAt)) {
        title = candidate;
        seenAt = instance.lastSeen;
      }
    }
    return title;
  }

  /// What the leak is called in a list: its likely cause, or, when that is not
  /// known, the type of the object that leaked. For a resource that was never
  /// closed, its label, which says which one it is.
  String get title => kind == LeakKind.resource ? reason : (cause ?? leakedType);

  /// The instance seen last. Of instances seen together, the one found first.
  LeakInstance get latest => _seenLast(instances)!;

  /// The instance seen last that has a path: the freshest account of how the leak
  /// is held.
  LeakInstance? get latestTraced => _seenLast(instances.where((instance) => instance.trace != null));

  static LeakInstance? _seenLast(Iterable<LeakInstance> instances) {
    LeakInstance? last;
    for (final instance in instances) {
      if (last == null || instance.lastSeen.isAfter(last.lastSeen)) last = instance;
    }
    return last;
  }

  /// Whether a step of the path that holds the leak is LeakSentry's own code, which
  /// is a bug in LeakSentry that this screen would rather show than hide.
  bool get isInternal => instances.any((instance) => instance.trace?.isInternal ?? false);

  LeakGroup _copy({List<LeakInstance>? instances, DateTime? lastSeen, bool? isUnread}) => LeakGroup(
    id: id,
    kind: kind,
    leakedType: leakedType,
    reason: reason,
    instances: instances ?? this.instances,
    firstSeen: firstSeen,
    lastSeen: lastSeen ?? this.lastSeen,
    isUnread: isUnread ?? this.isUnread,
  );
}

/// Where a scan is.
enum ScanStatus {
  /// The heap was dumped and the analysis is running.
  running,

  /// The analysis finished.
  succeeded,

  /// The heap could not be dumped, or the analysis failed.
  failed,
}

/// A leak as one scan found it.
class ScanLeak {
  const ScanLeak({
    required this.groupId,
    required this.leakedType,
    required this.reason,
    required this.count,
    required this.isNew,
    this.creationSite,
    this.watchSite,
    this.classSite,
    this.creationSiteGap,
  });

  /// The [LeakGroup.id] of the leak. The group may be gone by now.
  final String groupId;
  final String leakedType;
  final String reason;

  /// How many objects this scan found.
  final int count;

  /// Whether this scan was the first to find the leak this belongs to. Everything the
  /// scan found that is held the same way is new together.
  final bool isNew;

  final CreationSite? creationSite;
  final CreationSite? watchSite;
  final CreationSite? classSite;
  final CreationSiteGap? creationSiteGap;
}

/// One heap dump and its analysis: what the Scans screen shows as one row.
class ScanRecord {
  const ScanRecord({
    required this.id,
    required this.time,
    required this.status,
    required this.heldCount,
    this.trigger,
    this.step,
    this.progress = 0,
    this.leaks = const [],
    this.releasedCount = 0,
    this.analysisDuration,
    this.failure,
    this.willRetry = false,
  });

  /// The id of the `HeapDumpEvent`, or made up for a dump that failed.
  final String id;

  final DateTime time;
  final ScanStatus status;

  /// How many retained objects were in the dump.
  final int heldCount;

  /// Why the heap was dumped, as the trigger words it.
  final String? trigger;

  /// The step the analysis is on, while it [running].
  final AnalysisStep? step;

  /// How far along the analysis is, from 0 to 1.
  final double progress;

  final List<ScanLeak> leaks;

  /// How many of the objects had been released by the time the analysis looked.
  final int releasedCount;

  final Duration? analysisDuration;

  /// What went wrong, when [status] is [ScanStatus.failed].
  final String? failure;

  /// Whether a failed dump is tried again.
  final bool willRetry;

  /// How many distinct leaks this scan found. The leaks listed are one per kind of
  /// object it found, and objects held the same way are one leak.
  int get leakCount => {for (final leak in leaks) leak.groupId}.length;

  /// How many distinct leaks this scan found for the first time.
  int get newCount => {
    for (final leak in leaks)
      if (leak.isNew) leak.groupId,
  }.length;

  ScanRecord _copy({
    ScanStatus? status,
    AnalysisStep? step,
    double? progress,
    List<ScanLeak>? leaks,
    int? releasedCount,
    Duration? analysisDuration,
    String? failure,
  }) => ScanRecord(
    id: id,
    time: time,
    status: status ?? this.status,
    heldCount: heldCount,
    trigger: trigger,
    step: step ?? this.step,
    progress: progress ?? this.progress,
    leaks: leaks ?? this.leaks,
    releasedCount: releasedCount ?? this.releasedCount,
    analysisDuration: analysisDuration ?? this.analysisDuration,
    failure: failure ?? this.failure,
    willRetry: willRetry,
  );
}

/// The leaks found so far, grouped as distinct leaks, and the scans that found
/// them: what the screens show. It listens to the engine's events, and
/// notifies when anything changes.
///
/// The hub keeps its own first-seen-per-signature view, which the `LeakSentry`
/// API exposes. This is separate on purpose: it counts every scan, remembers what
/// has been read, and can be cleared without touching that API's history.
class LeakCatalog extends ChangeNotifier implements LeakSentryInternal {
  /// [groupKey] says which leak a report belongs to: reports with the same key are
  /// one leak. By default that is the fingerprint of the trace, so what is held by
  /// the same likely cause is one leak, whatever it is and wherever it was created;
  /// a report that has no fingerprint is a leak of its own signature.
  LeakCatalog({DateTime Function()? now, this.maxScans = 20, String Function(LeakReport report)? groupKey})
    : _now = now ?? DateTime.now,
      _groupKey = groupKey ?? _fingerprintOrSignature;

  final DateTime Function() _now;
  final String Function(LeakReport report) _groupKey;

  static String _fingerprintOrSignature(LeakReport report) {
    final fingerprint = report.trace?.fingerprint;
    if (fingerprint != null) return 'fp:$fingerprint';
    // A resource's signature is its type and label, so two acquired in different places, with the
    // same default label, would be one leak that shows only the first place. A retained object's
    // signature already has the place in it.
    final site = report.creationSite;
    if (report.confidence == LeakConfidence.resourceNeverClosed && site != null) {
      return 'sig:${report.signature}|${site.uri}:${site.line}';
    }
    return 'sig:${report.signature}';
  }

  /// How many scans are kept. The oldest go first.
  final int maxScans;

  final Map<String, LeakGroup> _groups = {};
  final List<ScanRecord> _scans = [];
  List<LeakGroup>? _sorted;
  bool _dumping = false;
  bool _disposed = false;
  int _failedDumps = 0;

  /// The time as the catalog counts it: what "5 min ago" counts from.
  DateTime now() => _now();

  /// The distinct leaks: the most objects first, and of those the most recently
  /// found first. Leaks that tie keep the order they were first found in.
  List<LeakGroup> get groups => _sorted ??= _sortedGroups();

  List<LeakGroup> _sortedGroups() {
    final all = _groups.values.toList();
    final foundAt = {for (var i = 0; i < all.length; i++) all[i].id: i};
    all.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      final byRecency = b.lastSeen.compareTo(a.lastSeen);
      return byRecency != 0 ? byRecency : foundAt[a.id]!.compareTo(foundAt[b.id]!);
    });
    return List.unmodifiable(all);
  }

  /// How many leaks are distinct.
  int get leakCount => _groups.length;

  /// How many objects leaked, over every leak.
  int get objectCount => _groups.values.fold(0, (total, group) => total + group.count);

  /// How many leaks haven't been opened since they were found.
  int get unreadCount => _groups.values.where((group) => group.isUnread).length;

  /// The scans, the latest first.
  List<ScanRecord> get scans => List.unmodifiable(_scans);

  /// Whether the heap is being dumped right now.
  bool get isDumping => _dumping;

  /// The scan whose analysis is running, if one is.
  ScanRecord? get runningScan {
    for (final scan in _scans) {
      if (scan.status == ScanStatus.running) return scan;
    }
    return null;
  }

  LeakGroup? groupById(String id) => _groups[id];

  /// Marks the leak as opened.
  void markRead(String id) {
    final group = _groups[id];
    if (group == null || !group.isUnread) return;
    _groups[id] = group._copy(isUnread: false);
    _changed();
  }

  /// Forgets every leak and every scan.
  void clear() {
    if (_groups.isEmpty && _scans.isEmpty) return;
    _groups.clear();
    _scans.clear();
    _changed();
  }

  /// Takes in what an event says. The engine sends every event here before any
  /// listener hears it.
  void onEvent(LeakSentryEvent event) {
    if (_disposed) return;
    switch (event) {
      case DumpingHeapEvent():
        if (_dumping) return;
        _dumping = true;
        notifyListeners();
      case HeapDumpEvent():
        _dumping = false;
        _addScan(
          ScanRecord(
            id: event.uniqueId,
            time: _now(),
            status: ScanStatus.running,
            heldCount: event.dump.objects.length,
            trigger: event.reason,
          ),
        );
      case HeapDumpFailedEvent():
        // A failed dump carries the id of the dump before it (the id of one
        // chain of events is only replaced when the heap is dumped), so it is
        // a scan of its own and must not be mistaken for that one.
        _dumping = false;
        _addScan(
          ScanRecord(
            id: 'failed-${_failedDumps++}',
            time: _now(),
            status: ScanStatus.failed,
            heldCount: 0,
            failure: '${event.exception}',
            willRetry: event.willRetryLater,
          ),
        );
      case HeapAnalysisProgressEvent():
        _updateScan(event.uniqueId, (scan) => scan._copy(step: event.step, progress: event.progressPercent));
      case HeapAnalysisSucceededEvent():
        _analysisSucceeded(event);
      case HeapAnalysisFailedEvent():
        _updateScan(
          event.uniqueId,
          (scan) => scan._copy(
            status: ScanStatus.failed,
            failure: '${event.heapAnalysis.exception}',
            analysisDuration: event.heapAnalysis.analysisDuration,
          ),
        );
    }
  }

  /// Takes in the report of a resource that was garbage collected unclosed.
  void addResourceLeak(LeakReport report) {
    if (_disposed) return;
    _absorb(report, _now());
    _changed();
  }

  void _analysisSucceeded(HeapAnalysisSucceededEvent event) {
    final analysis = event.heapAnalysis;
    final now = _now();
    final found = <ScanLeak>[];
    final foundHere = <String>{};
    for (final report in analysis.leaks) {
      final id = _groupIdOf(report);
      if (_absorb(report, now)) foundHere.add(id);
      found.add(
        ScanLeak(
          groupId: id,
          leakedType: '${report.type}',
          reason: report.reason,
          count: report.occurrenceCount,
          isNew: foundHere.contains(id),
          creationSite: report.creationSite,
          watchSite: report.watchSite,
          classSite: report.classSite,
          creationSiteGap: report.creationSiteGap,
        ),
      );
    }
    final existing = _scans.indexWhere((scan) => scan.id == event.uniqueId);
    if (existing < 0) {
      // The scan began before this catalog was listening, or a custom dumper
      // sent no dump event. Its analysis is still worth listing.
      _scans.insert(
        0,
        ScanRecord(
          id: event.uniqueId,
          time: now,
          status: ScanStatus.succeeded,
          heldCount: analysis.dump.objects.length,
          leaks: found,
          releasedCount: analysis.unreachableObjectCount,
          analysisDuration: analysis.analysisDuration,
        ),
      );
      _trimScans();
    } else {
      _scans[existing] = _scans[existing]._copy(
        status: ScanStatus.succeeded,
        progress: 1,
        leaks: found,
        releasedCount: analysis.unreachableObjectCount,
        analysisDuration: analysis.analysisDuration,
      );
    }
    _changed();
  }

  /// Adds [report] to its leak, making the leak if it is new. Returns whether
  /// it is new.
  bool _absorb(LeakReport report, DateTime now) {
    final id = _groupIdOf(report);
    final group = _groups[id];
    if (group == null) {
      _groups[id] = LeakGroup(
        id: id,
        kind: report.confidence == LeakConfidence.resourceNeverClosed ? LeakKind.resource : LeakKind.retained,
        leakedType: '${report.type}',
        reason: report.reason,
        instances: List.unmodifiable([LeakInstance.firstFound(report, now)]),
        firstSeen: now,
        lastSeen: now,
        isUnread: true,
      );
      return true;
    }
    final index = group.instances.indexWhere((instance) => instance.signature == report.signature);
    final instances = [...group.instances];
    if (index < 0) {
      instances.add(LeakInstance.firstFound(report, now));
    } else {
      instances[index] = instances[index].foundAgain(report, now);
    }
    _groups[id] = group._copy(instances: List.unmodifiable(instances), lastSeen: now);
    return false;
  }

  /// What a report is grouped by. Reports of resources are kept apart from
  /// those of retained objects, whatever their keys.
  String _groupIdOf(LeakReport report) {
    final key = _groupKey(report);
    return report.confidence == LeakConfidence.resourceNeverClosed ? 'res:$key' : key;
  }

  void _addScan(ScanRecord scan) {
    _scans.insert(0, scan);
    _trimScans();
    _changed();
  }

  void _trimScans() {
    if (_scans.length > maxScans) _scans.removeRange(maxScans, _scans.length);
  }

  void _updateScan(String id, ScanRecord Function(ScanRecord scan) update) {
    final index = _scans.indexWhere((scan) => scan.id == id);
    if (index < 0) return;
    _scans[index] = update(_scans[index]);
    _changed();
  }

  void _changed() {
    _sorted = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
