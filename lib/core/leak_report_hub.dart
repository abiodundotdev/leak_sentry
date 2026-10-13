import 'dart:async';

import 'package:leak_sentry/models/leak_report.dart';

/// Collects the leaks that were found, merging repeats of the same one.
///
/// The leaks are kept in memory only: none survives a restart of the app.
class LeakReportHub {
  final StreamController<LeakReport> _controller = StreamController<LeakReport>.broadcast();
  final List<LeakReport> _history = [];
  final Map<String, LeakReport> _bySignature = {};

  /// Emits a [LeakReport] the first time a given kind of leak is seen. Repeats
  /// of the same [LeakReport.signature] add to [LeakReport.occurrenceCount] of
  /// the existing report instead.
  Stream<LeakReport> get leaks => _controller.stream;

  /// Every distinct leak found so far this session.
  List<LeakReport> get leakHistory => List.unmodifiable(_history);

  /// Adds [report]. Returns whether it is a leak not seen before.
  bool add(LeakReport report) {
    final existing = _bySignature[report.signature];
    if (existing != null) {
      existing.occurrenceCount += report.occurrenceCount;
      return false;
    }
    _bySignature[report.signature] = report;
    _history.add(report);
    _controller.add(report);
    return true;
  }

  /// Adds every report, and returns the signatures of those not seen before.
  Set<String> addAll(Iterable<LeakReport> reports) => {
    for (final report in reports)
      if (add(report)) report.signature,
  };

  /// Throws if any leak was found so far this session.
  void expectNoLeaks() {
    if (_history.isEmpty) return;
    throw StateError('leak_sentry detected ${_history.length} leak(s):\n${_history.join('\n')}');
  }

  /// Forgets every leak found so far.
  void clear() {
    _history.clear();
    _bySignature.clear();
  }
}
