import 'package:flutter/material.dart';
import 'package:leak_sentry/ui/tokens.dart';

/// A titled block on a surface: the unit the detail screen and the settings are
/// built from.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, required this.child, this.padding = const EdgeInsets.all(16)});

  final String? title;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    // A Material, not a coloured box: a tile or a button on the card paints its
    // ink on the nearest Material, and a box in between would hide it.
    return Material(
      color: LeakSentryColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LeakSentryMetrics.cardRadius),
        side: const BorderSide(color: LeakSentryColors.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Text(
                title!,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  color: LeakSentryColors.muted,
                ),
              ),
              const SizedBox(height: 10),
            ],
            child,
          ],
        ),
      ),
    );
  }
}
