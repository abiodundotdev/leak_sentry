import 'package:flutter/widgets.dart';
import 'package:leak_sentry/core/internal_leak_sentry.dart';
import 'package:leak_sentry/models/leak_sentry_internal.dart';
import 'package:leak_sentry/object_watcher/scheduler.dart';

/// Builds with the time "5 min ago" counts from, and builds again with a later
/// one every [interval], so that a label that was "just now" when the screen
/// opened does not stay so.
///
/// The refresh goes through the engine's scheduler, which a test drives by hand,
/// so no timer is left running when a test ends.
class NowBuilder extends StatefulWidget {
  const NowBuilder({
    super.key,
    required this.engine,
    required this.builder,
    this.interval = const Duration(seconds: 30),
  });

  final InternalLeakSentry engine;
  final Widget Function(BuildContext context, DateTime now) builder;
  final Duration interval;

  @override
  State<NowBuilder> createState() => _NowBuilderState();
}

class _NowBuilderState extends State<NowBuilder> implements LeakSentryInternal {
  late DateTime _now = widget.engine.catalog.now();
  ScheduledTask? _refresh;

  @override
  void initState() {
    super.initState();
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    _refresh = widget.engine.scheduler.postDelayed(widget.interval, () {
      if (!mounted) return;
      setState(() => _now = widget.engine.catalog.now());
      _scheduleRefresh();
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _now);
}
