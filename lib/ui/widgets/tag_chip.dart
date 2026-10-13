import 'package:flutter/material.dart';
import 'package:leak_sentry/ui/tokens.dart';

/// A small outlined label: NEW, or what kind of leak this is.
class TagChip extends StatelessWidget {
  const TagChip(
    this.label, {
    super.key,
    this.color = LeakSentryColors.muted,
    this.line = LeakSentryColors.outline,
  });

  /// The accent one, for what is new.
  const TagChip.accent(this.label, {super.key}) : color = LeakSentryColors.accent, line = LeakSentryColors.accentLine;

  /// The cautious one, for a kind of leak that needs a different reading.
  const TagChip.caution(this.label, {super.key}) : color = LeakSentryColors.caution, line = LeakSentryColors.cautionLine;

  final String label;
  final Color color;
  final Color line;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: line)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Text(
          label,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: color),
        ),
      ),
    );
  }
}
