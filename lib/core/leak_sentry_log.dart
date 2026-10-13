import 'package:flutter/foundation.dart';

/// Where LeakSentry writes its log lines. Assign an implementation to
/// [LeakSentryLog.logger] to receive them.
abstract interface class LeakSentryLogger {
  void d(String message, [Object? error, StackTrace? stackTrace]);
}

/// Logs through [debugPrint], with a `LeakSentry:` prefix on the message and
/// on the error.
class ConsoleLeakSentryLogger implements LeakSentryLogger {
  const ConsoleLeakSentryLogger();

  @override
  void d(String message, [Object? error, StackTrace? stackTrace]) {
    debugPrint('LeakSentry: $message');
    if (error != null) debugPrint('LeakSentry: $error');
    if (stackTrace != null) debugPrint('$stackTrace');
  }
}

/// The global log. Silent until a [logger] is set; `LeakSentry.install` sets a
/// [ConsoleLeakSentryLogger] outside of release builds, so a release build logs
/// nothing unless the app sets a logger itself.
abstract final class LeakSentryLog {
  static LeakSentryLogger? logger;

  /// Whether to log every object that gets watched.
  ///
  /// Flutter disposes hundreds of `State`s and notifiers on every navigation,
  /// so a line for each one is left out unless this is set.
  static bool verbose = false;

  /// Logs the result of [message], which is only built when a logger is set.
  static void d(String Function() message, {Object? error, StackTrace? stackTrace}) {
    final current = logger;
    if (current == null) return;
    current.d(message(), error, stackTrace);
  }

  /// Like [d], for lines that would drown the rest: only logged when [verbose].
  static void v(String Function() message) {
    if (verbose) d(message);
  }
}
