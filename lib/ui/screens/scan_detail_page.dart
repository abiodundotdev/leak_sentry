import 'package:flutter/material.dart';
import 'package:leak_sentry/core/internal_leak_sentry.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/format.dart';
import 'package:leak_sentry/ui/now_builder.dart';
import 'package:leak_sentry/ui/site_summary.dart';
import 'package:leak_sentry/ui/skin.dart';
import 'package:leak_sentry/ui/tokens.dart';
import 'package:leak_sentry/ui/widgets/empty_state.dart';
import 'package:leak_sentry/ui/widgets/page_column.dart';
import 'package:leak_sentry/ui/widgets/section_card.dart';
import 'package:leak_sentry/ui/widgets/site_line.dart';
import 'package:leak_sentry/ui/widgets/tag_chip.dart';

/// One scan: why it ran, what it found, and where each leak it found came from.
class ScanDetailPage extends StatelessWidget {
  const ScanDetailPage({super.key, required this.engine, required this.scanId, required this.onOpenLeak});

  final InternalLeakSentry engine;
  final String scanId;

  /// Opens the leak with this `LeakGroup.id`.
  final void Function(String groupId) onOpenLeak;

  @override
  Widget build(BuildContext context) {
    return LeakSentrySkin(
      child: Scaffold(
        appBar: AppBar(title: const Text(LeakSentryCopy.scanTitle)),
        body: ListenableBuilder(
          listenable: engine.catalog,
          builder: (context, _) {
            final scan = engine.catalog.scans.where((scan) => scan.id == scanId).firstOrNull;
            if (scan == null) {
              return const EmptyState(
                icon: Icons.history_toggle_off,
                title: LeakSentryCopy.scanGone,
                body: LeakSentryCopy.scanGoneBody,
              );
            }
            return NowBuilder(
              engine: engine,
              builder: (context, now) => _ScanBody(
                scan: scan,
                now: now,
                titleOf: (groupId) => engine.catalog.groupById(groupId)?.title,
                onOpenLeak: onOpenLeak,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ScanBody extends StatelessWidget {
  const _ScanBody({required this.scan, required this.now, required this.titleOf, required this.onOpenLeak});

  final ScanRecord scan;
  final DateTime now;

  /// What the leak with this `LeakGroup.id` is called now, or null if it is gone.
  final String? Function(String groupId) titleOf;
  final void Function(String groupId) onOpenLeak;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final failure = scan.failure;
    // What was found, under the leak it belongs to, as the Leaks tab lists it: leaks held the same
    // way are one leak, and each kind of object in it keeps the place it came from.
    final byLeak = <String, List<ScanLeak>>{};
    for (final leak in scan.leaks) {
      byLeak.putIfAbsent(leak.groupId, () => []).add(leak);
    }
    final leaks = byLeak.entries.toList();
    return ListView(
      padding: EdgeInsets.only(bottom: bottom + 24),
      children: [
        PageColumn(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(LeakSentryMetrics.pagePadding, 4, LeakSentryMetrics.pagePadding, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  switch (scan.status) {
                    ScanStatus.running => LeakSentryCopy.scanRunning,
                    ScanStatus.succeeded => LeakSentryCopy.scanSummary(scan.heldCount, scan.leakCount, scan.newCount),
                    ScanStatus.failed => LeakSentryCopy.scanFailed,
                  },
                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: LeakSentryColors.text),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    formatAgo(scan.time, now),
                    if (scan.analysisDuration != null) LeakSentryCopy.scanTook(formatDuration(scan.analysisDuration!)),
                  ].join(' · '),
                  style: const TextStyle(fontSize: 13, color: LeakSentryColors.muted),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (scan.trigger != null) _line(LeakSentryCopy.scanReason(scan.trigger!)),
                      if (scan.status != ScanStatus.failed || scan.heldCount > 0) _line(LeakSentryCopy.scanDetailHeld(scan.heldCount)),
                      if (scan.releasedCount > 0) _line(LeakSentryCopy.scanReleased(scan.releasedCount)),
                      if (failure != null) _line(failure, color: LeakSentryColors.caution),
                    ],
                  ),
                ),
                if (scan.status == ScanStatus.succeeded) ...[
                  const SizedBox(height: 12),
                  SectionCard(
                    title: LeakSentryCopy.scanDetailLeaks,
                    child: scan.leaks.isEmpty
                        ? const Text(LeakSentryCopy.scanDetailNoLeaks, style: TextStyle(fontSize: 13, color: LeakSentryColors.muted))
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var i = 0; i < leaks.length; i++) ...[
                                if (i > 0) const Divider(height: 20),
                                _LeakBlock(
                                  title: titleOf(leaks[i].key) ?? leaks[i].value.first.leakedType,
                                  leaks: leaks[i].value,
                                  onTap: () => onOpenLeak(leaks[i].key),
                                ),
                              ],
                            ],
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _line(String text, {Color color = LeakSentryColors.muted}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text(text, style: TextStyle(fontSize: 13, height: 1.4, color: color)),
  );
}

/// One leak a scan found: what it is called, and under it each kind of object of it that was found, with
/// the place it came from.
class _LeakBlock extends StatelessWidget {
  const _LeakBlock({required this.title, required this.leaks, required this.onTap});

  final String title;
  final List<ScanLeak> leaks;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final total = leaks.fold<int>(0, (sum, leak) => sum + leak.count);
    final isNew = leaks.any((leak) => leak.isNew);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(breakable(title, after: '.'), style: LeakSentryText.mono(size: 14, weight: FontWeight.w700)),
                ),
                if (isNew) const Padding(padding: EdgeInsets.only(left: 8, right: 8), child: TagChip.accent(LeakSentryCopy.tagNew)),
                Text(LeakSentryCopy.objectsFound(total), style: const TextStyle(fontSize: 12, color: LeakSentryColors.dim)),
              ],
            ),
            for (final leak in leaks) ...[
              const SizedBox(height: 6),
              _FoundObject(leak: leak, showType: leak.leakedType != title || leaks.length > 1),
            ],
          ],
        ),
      ),
    );
  }
}

class _FoundObject extends StatelessWidget {
  const _FoundObject({required this.leak, required this.showType});

  final ScanLeak leak;

  /// Whether to say what kind of object it is: not when the title already says.
  final bool showType;

  @override
  Widget build(BuildContext context) {
    final site = summarizeSites(created: leak.creationSite, watched: leak.watchSite, declared: leak.classSite);
    final pin = describePinParts(site);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showType)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              '${leak.leakedType} · ${LeakSentryCopy.objectsFound(leak.count)}',
              style: const TextStyle(fontSize: 12, color: LeakSentryColors.muted),
            ),
          ),
        LocationPin(text: pin.place, detail: pin.member, missing: site.isMissing, fallback: site.isFallback),
      ],
    );
  }
}
