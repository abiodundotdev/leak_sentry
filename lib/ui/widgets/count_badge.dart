import 'package:flutter/material.dart';
import 'package:leak_sentry/ui/tokens.dart';

/// How many objects a leak holds, in a ring. The ring is filled with the
/// accent while the leak is unread, and is plain once it has been opened.
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.count, this.unread = false, this.size = 44});

  final int count;
  final bool unread;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      padding: EdgeInsets.all(size * 0.14),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: unread ? LeakSentryColors.accent : LeakSentryColors.surfaceHigh,
        border: Border.all(color: unread ? LeakSentryColors.accent : LeakSentryColors.outline, width: 2),
      ),
      // Whatever the text scale, the number stays inside its ring.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          count > 99 ? '99+' : '$count',
          maxLines: 1,
          style: TextStyle(
            fontSize: size * 0.36,
            fontWeight: FontWeight.w700,
            color: unread ? LeakSentryColors.onAccent : LeakSentryColors.text,
          ),
        ),
      ),
    );
  }
}
