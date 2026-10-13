import 'dart:async';

import 'package:flutter/material.dart';
import 'package:leak_sentry/core/heap_dump_control.dart';
import 'package:leak_sentry/core/internal_leak_sentry.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/core/retain_instance_event.dart';
import 'package:leak_sentry/core/retained_notice.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/format.dart';
import 'package:leak_sentry/ui/now_builder.dart';
import 'package:leak_sentry/ui/tokens.dart';
import 'package:leak_sentry/ui/widgets/page_column.dart';
import 'package:leak_sentry/ui/widgets/section_card.dart';

/// The scans: what is being held right now, and every scan so far.
class ScansTab extends StatelessWidget {
  const ScansTab({super.key, required this.engine, required this.onOpenScan});

  final InternalLeakSentry engine;
  final void Function(ScanRecord scan) onOpenScan;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return ListenableBuilder(
      listenable: Listenable.merge([engine.catalog, engine.notices]),
      builder: (context, _) {
        final scans = engine.catalog.scans;
        return NowBuilder(
          engine: engine,
          builder: (context, now) => ListView(
            primary: false,
            padding: EdgeInsets.only(bottom: bottom + 16),
            children: [
              PageColumn(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(LeakSentryMetrics.pagePadding, 4, LeakSentryMetrics.pagePadding, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _StatusCard(engine: engine),
                      const SizedBox(height: 16),
                      if (scans.isEmpty)
                        const _NoScans()
                      else
                        for (final scan in scans) ...[
                          _ScanTile(scan: scan, now: now, onTap: () => onOpenScan(scan)),
                          const SizedBox(height: 10),
                        ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// What the scanning is doing right now, and the button that scans at once.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.engine});

  final InternalLeakSentry engine;

  @override
  Widget build(BuildContext context) {
    final status = _statusOf(engine);
    final permission = engine.heapDumpPermission;
    final cannotScan = permission is Nope && permission.block == HeapDumpBlock.notInstalled;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(status.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: LeakSentryColors.text)),
          if (status.body != null) ...[
            const SizedBox(height: 4),
            Text(status.body!, style: const TextStyle(fontSize: 13, height: 1.45, color: LeakSentryColors.muted)),
          ],
          if (status.progress != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: status.progress, minHeight: 6),
            ),
          ],
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: status.busy || cannotScan ? null : () => unawaited(engine.dumpHeap()),
              icon: const Icon(Icons.radar, size: 18),
              label: const Text(LeakSentryCopy.scanNow),
            ),
          ),
        ],
      ),
    );
  }
}

class _Status {
  const _Status(this.title, {this.body, this.progress, this.busy = false});

  final String title;
  final String? body;
  final double? progress;

  /// Whether a scan is under way, so another cannot be started.
  final bool busy;
}

_Status _statusOf(InternalLeakSentry engine) {
  final catalog = engine.catalog;
  final running = catalog.runningScan;
  if (running != null) {
    final step = running.step;
    return _Status(
      LeakSentryCopy.scanRunning,
      body: step == null ? LeakSentryCopy.scanStatusCapturing : LeakSentryCopy.analysisStep(step),
      progress: running.progress,
      busy: true,
    );
  }
  if (catalog.isDumping) return const _Status(LeakSentryCopy.scanRunning, body: LeakSentryCopy.scanStatusCapturing, busy: true);

  final notice = engine.notices.value;
  if (notice != null) {
    switch (notice.kind) {
      case RetainedNoticeKind.allClear:
        return const _Status(LeakSentryCopy.scanStatusAllClear, body: LeakSentryCopy.scanStatusAllClearBody);
      case RetainedNoticeKind.nothingOnRequest:
        return const _Status(LeakSentryCopy.scanStatusIdle, body: LeakSentryCopy.nothingHeldOnRequest);
      case RetainedNoticeKind.held:
        return _Status(LeakSentryCopy.scanStatusHeld(notice.objectCount), body: _whyHeld(engine, notice));
    }
  }
  final permission = engine.heapDumpPermission;
  return _Status(
    LeakSentryCopy.scanStatusIdle,
    body: permission is Nope ? LeakSentryCopy.blockSentence(permission.block) : LeakSentryCopy.scanStatusIdleBody,
  );
}

String _whyHeld(InternalLeakSentry engine, RetainedNotice notice) => switch (notice.reason) {
  BelowThresholdEvent() => LeakSentryCopy.scanStatusWaiting(engine.config.retainedVisibleThreshold),
  DumpHappenedRecentlyEvent() => LeakSentryCopy.scanStatusRecent,
  DumpingDisabledEvent() => switch (engine.heapDumpPermission) {
    Nope(:final block) => LeakSentryCopy.blockSentence(block),
    _ => LeakSentryCopy.scanStatusIdleBody,
  },
  _ => LeakSentryCopy.scanStatusFailed,
};

class _NoScans extends StatelessWidget {
  const _NoScans();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24, horizontal: 8),
      child: Column(
        children: [
          Text(LeakSentryCopy.scansEmptyTitle, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: LeakSentryColors.text)),
          SizedBox(height: 6),
          Text(
            LeakSentryCopy.scansEmptyBody,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.45, color: LeakSentryColors.muted),
          ),
        ],
      ),
    );
  }
}

class _ScanTile extends StatelessWidget {
  const _ScanTile({required this.scan, required this.now, required this.onTap});

  final ScanRecord scan;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, color, title) = switch (scan.status) {
      ScanStatus.running => (Icons.hourglass_top_rounded, LeakSentryColors.accent, LeakSentryCopy.scanRunning),
      ScanStatus.succeeded => (
        scan.leaks.isEmpty ? Icons.check_circle_outline : Icons.water_drop_outlined,
        scan.leaks.isEmpty ? LeakSentryColors.accent : LeakSentryColors.dangerText,
        LeakSentryCopy.scanSummary(scan.heldCount, scan.leakCount, scan.newCount),
      ),
      ScanStatus.failed => (
        Icons.error_outline,
        LeakSentryColors.caution,
        scan.willRetry ? LeakSentryCopy.scanFailedWillRetry : LeakSentryCopy.scanFailed,
      ),
    };
    return Material(
      color: LeakSentryColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LeakSentryMetrics.cardRadius),
        side: const BorderSide(color: LeakSentryColors.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: LeakSentryColors.text)),
                    const SizedBox(height: 2),
                    Text(formatAgo(scan.time, now), style: const TextStyle(fontSize: 12, color: LeakSentryColors.dim)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: LeakSentryColors.dim),
            ],
          ),
        ),
      ),
    );
  }
}
