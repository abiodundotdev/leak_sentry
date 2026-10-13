import 'package:flutter/material.dart';
import 'package:leak_sentry/core/internal_leak_sentry.dart';
import 'package:leak_sentry/models/leak_sentry_internal.dart';

/// The route every LeakSentry screen is shown on. It tells the engine when a
/// screen comes and goes, so that the badge can get out of the way, and it is
/// LeakSentry's own, so it is never watched for leaks.
class LeakSentryRoute<T> extends MaterialPageRoute<T> implements LeakSentryInternal {
  LeakSentryRoute({required this.engine, required super.builder, super.settings});

  final InternalLeakSentry engine;

  @override
  void install() {
    super.install();
    engine.screenOpened();
  }

  @override
  void dispose() {
    engine.screenClosed();
    super.dispose();
  }
}
