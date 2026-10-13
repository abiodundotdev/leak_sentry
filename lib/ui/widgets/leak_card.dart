import 'package:flutter/material.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/format.dart';
import 'package:leak_sentry/ui/site_summary.dart';
import 'package:leak_sentry/ui/tokens.dart';
import 'package:leak_sentry/ui/widgets/count_badge.dart';
import 'package:leak_sentry/ui/widgets/site_line.dart';
import 'package:leak_sentry/ui/widgets/tag_chip.dart';

/// One distinct leak, as a row of the leaks list: how many objects it holds, what
/// it is, where it came from, and when it was last seen.
class LeakCard extends StatelessWidget {
  const LeakCard({super.key, required this.group, required this.now, required this.onTap});

  final LeakGroup group;

  /// The time "seen ... ago" counts from.
  final DateTime now;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final site = summarizeSite(group);
    final pin = describePinParts(site);
    final isResource = group.kind == LeakKind.resource;
    final hasCause = group.cause != null;
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
              CountBadge(count: group.count, unread: group.isUnread),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      breakable(group.title, after: '.'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: LeakSentryText.mono(size: 15, weight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isResource
                          ? LeakSentryCopy.resourceNeverClosed
                          : (hasCause ? LeakSentryCopy.holds(glueAnd(describeTypes(group.leakedTypes))) : group.reason),
                      style: hasCause
                          ? LeakSentryText.mono(size: 13, color: LeakSentryColors.muted)
                          : const TextStyle(fontSize: 13, color: LeakSentryColors.muted),
                    ),
                    if (isResource || group.isInternal) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (isResource) const TagChip.caution(LeakSentryCopy.tagResource),
                          if (group.isInternal) const TagChip.caution(LeakSentryCopy.tagInternal),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    LocationPin(text: pin.place, detail: pin.member, missing: site.isMissing, fallback: site.isFallback),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (group.isUnread) const TagChip.accent(LeakSentryCopy.tagNew),
                        Text(
                          LeakSentryCopy.seenAgo(formatAgo(group.lastSeen, now)),
                          style: const TextStyle(fontSize: 12, color: LeakSentryColors.dim),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
