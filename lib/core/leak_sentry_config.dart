import 'package:leak_sentry/core/heap_dumper.dart';
import 'package:leak_sentry/core/leak_sentry_event.dart';

/// LeakSentry's configuration.
///
/// Change it by assigning `LeakSentry.config = LeakSentry.config.copyWith(...)`.
class LeakSentryConfig {
  const LeakSentryConfig({
    this.dumpHeap = true,
    this.retainedVisibleThreshold = 5,
    this.enableRetainingPathAnalysis = true,
    this.maxRetainingPathLookups = 20,
    this.heapDumper,
    this.eventListeners,
  });

  /// Whether LeakSentry dumps the heap when enough retained objects are found.
  /// It has to be true for LeakSentry to report leaks, but you may want to turn
  /// it off for a while (a product demo, for example).
  ///
  /// Defaults to true.
  final bool dumpHeap;

  /// While the app is visible, LeakSentry waits for at least this many retained
  /// objects before dumping the heap. A heap dump freezes the app, which is
  /// frustrating for a developer who is trying to work.
  ///
  /// Once the app becomes invisible, the heap is dumped after the retained
  /// delay whatever the count. A higher threshold bothers developers less, but
  /// it can miss some leaks.
  ///
  /// Defaults to 5.
  final int retainedVisibleThreshold;

  /// Whether to look up the retaining path of each distinct leak through the VM
  /// service. It has no effect where no VM service is available.
  ///
  /// Defaults to true.
  final bool enableRetainingPathAnalysis;

  /// The most retaining-path lookups per analysis. Each one walks the whole
  /// heap inside the VM and pauses the app, so a dump with many distinct leaks
  /// gets the paths of the first ones only.
  ///
  /// Defaults to 20.
  final int maxRetainingPathLookups;

  /// Dumps the heap. Replace it to change how the retained set is captured.
  /// Null means the default, which captures the retained objects.
  final HeapDumper? heapDumper;

  /// Listeners for [LeakSentryEvent]s. Null means the defaults, which log the
  /// events and run the analysis. Start from `LeakSentry.defaultEventListeners`
  /// to add one without losing those.
  final List<LeakSentryEventListener>? eventListeners;

  LeakSentryConfig copyWith({
    bool? dumpHeap,
    int? retainedVisibleThreshold,
    bool? enableRetainingPathAnalysis,
    int? maxRetainingPathLookups,
    HeapDumper? heapDumper,
    List<LeakSentryEventListener>? eventListeners,
  }) => LeakSentryConfig(
    dumpHeap: dumpHeap ?? this.dumpHeap,
    retainedVisibleThreshold: retainedVisibleThreshold ?? this.retainedVisibleThreshold,
    enableRetainingPathAnalysis: enableRetainingPathAnalysis ?? this.enableRetainingPathAnalysis,
    maxRetainingPathLookups: maxRetainingPathLookups ?? this.maxRetainingPathLookups,
    heapDumper: heapDumper ?? this.heapDumper,
    eventListeners: eventListeners ?? this.eventListeners,
  );
}
