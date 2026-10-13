import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/retaining_element.dart';

/// Why a [LeakReport] was raised.
enum LeakConfidence {
  /// The object was expected to be garbage collected, was still reachable when
  /// its delay ended, and was still there after a forced GC.
  retainedAfterGc,

  /// A tracked resource (e.g. a `StreamController`) was garbage collected
  /// while still open — it was never explicitly closed.
  resourceNeverClosed,
}

/// Why a [LeakReport] has no retaining path.
enum RetainingPathGap {
  /// `LeakSentryConfig.enableRetainingPathAnalysis` is off.
  disabled,

  /// The app has no VM service to ask: a release build, the web, or none reachable.
  noVmService,

  /// The analysis had already looked up as many paths as
  /// `LeakSentryConfig.maxRetainingPathLookups` allows.
  lookupLimitReached,

  /// The VM had no id for the object: it was collected since the dump, or the
  /// VM service could not be used.
  objectUnavailable,

  /// The VM service could not be reached, or failed to answer the lookup.
  lookupFailed,
}

/// A human-readable retaining path: the chain of references holding an
/// object alive, from the object back to a GC root.
class RetainingPathInfo {
  const RetainingPathInfo({
    required this.gcRootType,
    required this.hops,
    this.elements = const [],
    this.totalLength,
  });

  /// The kind of GC root holding the object alive (e.g. `"stack"`,
  /// `"user global"`) — see `vm_service`'s `RetainingPath.gcRootType`.
  final String gcRootType;

  /// The chain of references from the leaked object to the GC root, e.g.
  /// `['_MyPageState.controller', '_AppState.pages']`.
  final List<String> hops;

  /// The same chain as plain data, in the same order as [hops]: the leaked
  /// object first, what is nearest the GC root last. Empty when a path was
  /// built without it.
  final List<RetainingElement> elements;

  /// How long the whole path is, when the VM cut it short (it keeps the
  /// elements nearest the leaked object). Null means [elements] is all of it.
  final int? totalLength;

  /// How many steps towards the GC root the VM left out.
  int get hiddenSteps {
    final total = totalLength;
    return total == null || total <= hops.length ? 0 : total - hops.length;
  }

  @override
  String toString() => [...hops, 'GC root ($gcRootType)'].join(' <- held by ');
}

/// A single detected leak.
class LeakReport {
  LeakReport({
    required this.type,
    required this.reason,
    required this.firstObservedAt,
    required this.detectedAt,
    required this.confidence,
    required this.signature,
    this.objectId,
    this.retainingPath,
    this.trace,
    this.acquiredAt,
    this.creationSite,
    this.watchSite,
    this.classSite,
    this.creationSiteGap,
    this.pathGap,
    this.occurrenceCount = 1,
  });

  /// Runtime type of the leaked object/resource.
  final Type type;

  /// Why this object/resource was expected to be gone (a caller-supplied
  /// reason, or a label for resource tracking).
  final String reason;

  /// When the object was first watched (when it was disposed, for lifecycle
  /// objects), or the resource was created.
  final DateTime firstObservedAt;

  /// When this leak was confirmed.
  final DateTime detectedAt;

  /// Which detection engine raised this, and how confident it is.
  final LeakConfidence confidence;

  /// Best-effort VM service object id, for diagnostics only.
  final String? objectId;

  /// Best-effort retaining path, only ever populated for
  /// [LeakConfidence.retainedAfterGc] leaks, and only when a VM service
  /// session is available and the analysis got to look it up.
  final RetainingPathInfo? retainingPath;

  /// [retainingPath] worked out: every step named as it is written in code, what
  /// each step is (in use, should be gone, unclear), which references are the likely
  /// causes, and the fingerprint that tells this leak from others. Null whenever
  /// there is no path, or the VM said nothing of what its steps are.
  final LeakTrace? trace;

  /// The stack trace captured when a tracked resource was created, only
  /// populated for [LeakConfidence.resourceNeverClosed] leaks.
  final StackTrace? acquiredAt;

  /// The line of application code that created the leaked object (or, for
  /// a tracked resource, started tracking it), when it could be determined.
  /// Only available for objects created after [LeakSentry] was mounted, and
  /// only where Flutter reports object creation (debug builds).
  final CreationSite? creationSite;

  /// Where the object was handed to `LeakSentry.objectWatcher.watch`, when no
  /// creation site is known: the next best place to start looking.
  final CreationSite? watchSite;

  /// Where the leaked object's class is declared, when the VM answered the
  /// retaining path lookup. What to show when no creation site is known, for
  /// example for a `State` that doesn't override `initState`.
  final CreationSite? classSite;

  /// Why neither [creationSite] nor [watchSite] is known. Never set when one is.
  final CreationSiteGap? creationSiteGap;

  /// Why there is no [retainingPath]. Never set when there is one, and only for
  /// leaks that could have had one.
  final RetainingPathGap? pathGap;

  /// A stable hash grouping repeated occurrences of what is likely "the
  /// same" leak (same type, confidence, and shape), so callers can dedupe.
  final String signature;

  /// How many times a leak matching [signature] has been detected in this
  /// session. Incremented in place instead of emitting a fresh report for
  /// every repeat.
  int occurrenceCount;

  @override
  String toString() =>
      'LeakReport($type, $confidence, reason: "$reason", '
      'occurrences: $occurrenceCount'
      '${_siteDescription()}'
      '${trace?.title != null ? ', likelyCause: ${trace!.title}' : ''}'
      '${retainingPath != null ? ', retainingPath: $retainingPath' : ''})';

  /// Where to start looking, or why that isn't known, so that a report printed
  /// by a failing test or a log always says.
  String _siteDescription() {
    if (creationSite != null) return ', createdAt: $creationSite';
    final fallback = [
      if (watchSite != null) ', watchedAt: $watchSite',
      if (watchSite == null && creationSiteGap != null) ', creation site unavailable (${creationSiteGap!.name})',
      if (classSite != null) ', classDeclaredAt: $classSite',
    ];
    return fallback.join();
  }
}
