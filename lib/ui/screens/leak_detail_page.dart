import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:leak_sentry/core/internal_leak_sentry.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/leak_sentry_internal.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/format.dart';
import 'package:leak_sentry/ui/now_builder.dart';
import 'package:leak_sentry/ui/report_text.dart';
import 'package:leak_sentry/ui/skin.dart';
import 'package:leak_sentry/ui/tokens.dart';
import 'package:leak_sentry/ui/trace_steps.dart';
import 'package:leak_sentry/ui/widgets/empty_state.dart';
import 'package:leak_sentry/ui/widgets/page_column.dart';
import 'package:leak_sentry/ui/widgets/section_card.dart';
import 'package:leak_sentry/ui/widgets/site_line.dart';
import 'package:leak_sentry/ui/widgets/tag_chip.dart';
import 'package:leak_sentry/ui/widgets/trace_timeline.dart';

/// One leak: where it was created, what is holding it, and the report to paste.
class LeakDetailPage extends StatefulWidget {
  const LeakDetailPage({super.key, required this.engine, required this.groupId});

  final InternalLeakSentry engine;

  /// The `LeakGroup.id` of the leak.
  final String groupId;

  @override
  State<LeakDetailPage> createState() => _LeakDetailPageState();
}

class _LeakDetailPageState extends State<LeakDetailPage> implements LeakSentryInternal {
  @override
  void initState() {
    super.initState();
    // Opening a leak is what reads it. Done once the page is up, because the list
    // behind it changes when it is read.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.engine.catalog.markRead(widget.groupId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    return LeakSentrySkin(
      child: ListenableBuilder(
        listenable: engine.catalog,
        builder: (context, _) {
          final group = engine.catalog.groupById(widget.groupId);
          return Scaffold(
            appBar: AppBar(
              title: const Text(LeakSentryCopy.leakTitle),
              actions: group == null
                  ? null
                  : [
                      IconButton(
                        tooltip: LeakSentryCopy.copyReport,
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: () => _copy(context, group),
                      ),
                      IconButton(
                        tooltip: LeakSentryCopy.printReport,
                        icon: const Icon(Icons.terminal_rounded),
                        onPressed: () => _print(context, group),
                      ),
                      const SizedBox(width: 4),
                    ],
            ),
            body: group == null
                ? const EmptyState(
                    icon: Icons.delete_outline,
                    title: LeakSentryCopy.leakCleared,
                    body: LeakSentryCopy.leakClearedBody,
                  )
                : NowBuilder(engine: engine, builder: (context, now) => _DetailBody(group: group, now: now)),
          );
        },
      ),
    );
  }

  void _copy(BuildContext context, LeakGroup group) {
    Clipboard.setData(ClipboardData(text: buildLeakReport(group, now: widget.engine.catalog.now())));
    _say(context, LeakSentryCopy.reportCopied);
  }

  void _print(BuildContext context, LeakGroup group) {
    // Long lines are wrapped: the console of a device cuts them.
    debugPrint(buildLeakReport(group, now: widget.engine.catalog.now()), wrapWidth: 900);
    _say(context, LeakSentryCopy.reportPrinted);
  }

  void _say(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.group, required this.now});

  final LeakGroup group;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final isResource = group.kind == LeakKind.resource;
    return ListView(
      padding: EdgeInsets.only(bottom: bottom + 24),
      children: [
        PageColumn(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(LeakSentryMetrics.pagePadding, 4, LeakSentryMetrics.pagePadding, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(breakable(group.title, after: '.'), style: LeakSentryText.mono(size: 19, weight: FontWeight.w700)),
                if (isResource || group.cause != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    isResource ? group.leakedType : LeakSentryCopy.holds(glueAnd(describeTypes(group.leakedTypes))),
                    style: LeakSentryText.mono(size: 12, color: LeakSentryColors.dim),
                  ),
                ],
                if (group.isInternal) ...[
                  const SizedBox(height: 8),
                  const Align(alignment: Alignment.centerLeft, child: TagChip.caution(LeakSentryCopy.tagInternal)),
                ],
                const SizedBox(height: 6),
                Text(
                  [countOf(group.count, 'object'), ..._seen(group, now)].join(' · '),
                  style: const TextStyle(fontSize: 13, color: LeakSentryColors.muted),
                ),
                const SizedBox(height: 16),
                _OriginCard(group: group),
                const SizedBox(height: 12),
                _PathCard(group: group),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// When the leak was found and last seen: said once when that was at the same time.
List<String> _seen(LeakGroup group, DateTime now) {
  final first = formatAgo(group.firstSeen, now);
  final last = formatAgo(group.lastSeen, now);
  return first == last
      ? [LeakSentryCopy.seen(last)]
      : [LeakSentryCopy.firstSeen(first), LeakSentryCopy.lastSeen(last)];
}

/// Where each instance of the leak was created, or why that is not known.
class _OriginCard extends StatelessWidget {
  const _OriginCard({required this.group});

  final LeakGroup group;

  @override
  Widget build(BuildContext context) {
    final instances = group.instances;
    return SectionCard(
      title: LeakSentryCopy.whereCreated,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < instances.length; i++) ...[
            if (i > 0) const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider(height: 1)),
            _OriginBlock(group: group, instance: instances[i], number: i + 1, total: instances.length),
          ],
        ],
      ),
    );
  }
}

class _OriginBlock extends StatelessWidget {
  const _OriginBlock({required this.group, required this.instance, required this.number, required this.total});

  final LeakGroup group;
  final LeakInstance instance;
  final int number;
  final int total;

  @override
  Widget build(BuildContext context) {
    final created = instance.creationSite;
    final watched = instance.watchSite;
    final declared = instance.classSite;
    final gap = instance.creationSiteGap;
    final createdLabel = group.kind == LeakKind.resource ? LeakSentryCopy.acquiredAt : LeakSentryCopy.createdAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (total > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${LeakSentryCopy.instanceNumber(number, total)} · ${instance.leakedType} · '
              '${LeakSentryCopy.objectsFound(instance.count)}',
              style: const TextStyle(fontSize: 12, color: LeakSentryColors.muted),
            ),
          ),
        if (created != null)
          SiteLine(label: createdLabel, site: created)
        else if (watched != null)
          SiteLine(label: LeakSentryCopy.watchedAt, site: watched, isFallback: true)
        else ...[
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.help_outline_rounded, size: 18, color: LeakSentryColors.caution),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  LeakSentryCopy.creationUnknown,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: LeakSentryColors.caution),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            gap == null ? LeakSentryCopy.creationUnknownNoReason : LeakSentryCopy.creationGap(gap),
            style: const TextStyle(fontSize: 13, height: 1.4, color: LeakSentryColors.muted),
          ),
          if (declared != null) ...[
            const SizedBox(height: 8),
            SiteLine(label: LeakSentryCopy.classDeclaredAt, site: declared, isFallback: true),
          ],
        ],
      ],
    );
  }
}

/// What holds the object: the path as a timeline, or why there is none.
class _PathCard extends StatelessWidget {
  const _PathCard({required this.group});

  final LeakGroup group;

  @override
  Widget build(BuildContext context) {
    if (group.kind == LeakKind.resource) {
      return const SectionCard(
        title: LeakSentryCopy.pathTitle,
        child: Text(
          LeakSentryCopy.resourceExplanation,
          style: TextStyle(fontSize: 13, height: 1.45, color: LeakSentryColors.muted),
        ),
      );
    }
    // The path of the instance seen last that has one; failing that, why the latest has none.
    final traced = group.latestTraced;
    final trace = traced?.trace;
    final Widget content;
    if (trace == null) {
      final gap = group.latest.pathGap;
      content = Text(
        gap == null ? LeakSentryCopy.pathUnknown : LeakSentryCopy.pathGap(gap),
        style: const TextStyle(fontSize: 13, height: 1.45, color: LeakSentryColors.muted),
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            LeakSentryCopy.pathHint,
            style: TextStyle(fontSize: 13, height: 1.45, color: LeakSentryColors.muted),
          ),
          if (group.instances.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                LeakSentryCopy.pathOfLatest(group.instances.length),
                style: const TextStyle(fontSize: 12, color: LeakSentryColors.muted),
              ),
            ),
          const SizedBox(height: 14),
          TraceTimeline(
            steps: timelineStepsOf(trace, leakedAt: _leakedAtOf(traced!)),
            startsAt: LeakSentryCopy.startsAt(trace.gcRootType),
            hiddenSteps: trace.hiddenSteps,
          ),
        ],
      );
    }
    return SectionCard(title: LeakSentryCopy.pathTitle, child: content);
  }
}

/// Where the object of [instance] came from, to say under the leaked object at the end of its
/// path: the best place known, and what it is the place of.
({String label, CreationSite site})? _leakedAtOf(LeakInstance instance) {
  final created = instance.creationSite;
  if (created != null) return (label: LeakSentryCopy.createdAt, site: created);
  final watched = instance.watchSite;
  if (watched != null) return (label: LeakSentryCopy.watchedAt, site: watched);
  final declared = instance.classSite;
  if (declared != null) return (label: LeakSentryCopy.classDeclaredAt, site: declared);
  return null;
}
