import 'package:flutter/widgets.dart';
import 'package:leak_sentry/ui/tokens.dart';

/// Keeps a page's content no wider than [LeakSentryMetrics.maxContentWidth],
/// centred: on a tablet or a desktop window it does not stretch across the
/// whole screen.
class PageColumn extends StatelessWidget {
  const PageColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: LeakSentryMetrics.maxContentWidth),
        child: child,
      ),
    );
  }
}
