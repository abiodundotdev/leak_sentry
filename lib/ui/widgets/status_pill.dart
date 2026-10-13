import 'package:flutter/material.dart';
import 'package:leak_sentry/analysis/node_status.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/tokens.dart';

/// What a step of a leak's path is: in use, should be gone, or unclear.
class StatusPill extends StatelessWidget {
  const StatusPill(this.status, {super.key});

  final NodeStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color, background, line) = switch (status) {
      NodeStatus.inUse => (
        LeakSentryCopy.statusInUse,
        LeakSentryColors.inUse,
        LeakSentryColors.inUseDeep,
        LeakSentryColors.inUseLine,
      ),
      NodeStatus.shouldBeGone => (
        LeakSentryCopy.statusShouldBeGone,
        LeakSentryColors.dangerText,
        LeakSentryColors.dangerDeep,
        LeakSentryColors.dangerLine,
      ),
      NodeStatus.unclear => (
        LeakSentryCopy.statusUnclear,
        LeakSentryColors.caution,
        LeakSentryColors.cautionDeep,
        LeakSentryColors.cautionLine,
      ),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: line),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
      ),
    );
  }
}
