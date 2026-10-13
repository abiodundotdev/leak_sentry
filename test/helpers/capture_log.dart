import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/leak_sentry_log.dart';

/// A [LeakSentryLogger] that keeps every line it is given.
class CapturingLogger implements LeakSentryLogger {
  final List<String> lines = [];
  final List<Object> errors = [];

  @override
  void d(String message, [Object? error, StackTrace? stackTrace]) {
    lines.add(message);
    if (error != null) errors.add(error);
  }
}

/// Routes LeakSentry's log to a [CapturingLogger] for the rest of the test.
/// With [verbose], the line for every watched object is logged too.
CapturingLogger captureLog({bool verbose = false}) {
  final previous = LeakSentryLog.logger;
  final previousVerbose = LeakSentryLog.verbose;
  final logger = CapturingLogger();
  LeakSentryLog.logger = logger;
  LeakSentryLog.verbose = verbose;
  addTearDown(() {
    LeakSentryLog.logger = previous;
    LeakSentryLog.verbose = previousVerbose;
  });
  return logger;
}
