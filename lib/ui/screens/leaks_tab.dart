import 'package:flutter/material.dart';
import 'package:leak_sentry/core/internal_leak_sentry.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/now_builder.dart';
import 'package:leak_sentry/ui/tokens.dart';
import 'package:leak_sentry/ui/widgets/empty_state.dart';
import 'package:leak_sentry/ui/widgets/leak_card.dart';
import 'package:leak_sentry/ui/widgets/page_column.dart';

/// The distinct leaks: the most objects first.
class LeaksTab extends StatelessWidget {
  const LeaksTab({super.key, required this.engine, required this.onOpenLeak});

  final InternalLeakSentry engine;
  final void Function(LeakGroup group) onOpenLeak;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine.catalog,
      builder: (context, _) {
        final catalog = engine.catalog;
        final groups = catalog.groups;
        if (groups.isEmpty) {
          return const EmptyState(
            icon: Icons.verified_outlined,
            title: LeakSentryCopy.leaksEmptyTitle,
            body: LeakSentryCopy.leaksEmptyBody,
          );
        }
        final bottom = MediaQuery.paddingOf(context).bottom;
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
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12, left: 2),
                        child: Text(
                          LeakSentryCopy.leaksSummary(catalog.leakCount, catalog.objectCount),
                          style: const TextStyle(fontSize: 13, color: LeakSentryColors.muted),
                        ),
                      ),
                      for (final group in groups) ...[
                        LeakCard(group: group, now: now, onTap: () => onOpenLeak(group)),
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
