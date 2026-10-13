import 'package:flutter/material.dart';
import 'package:leak_sentry/core/internal_leak_sentry.dart';
import 'package:leak_sentry/core/leak_sentry_tab.dart';
import 'package:leak_sentry/core/retain_instance_event.dart';
import 'package:leak_sentry/core/retained_notice.dart';
import 'package:leak_sentry/models/leak_sentry_internal.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/leak_sentry_route.dart';
import 'package:leak_sentry/ui/leak_sentry_screen.dart';
import 'package:leak_sentry/ui/tokens.dart';

/// Shows a small badge over your app while LeakSentry has leaks to show, and a
/// notice while objects are being held. Tap the badge to open the LeakSentry
/// screen; tap the notice to open the scans.
///
/// Typically placed with `MaterialApp.builder`, i.e. *above* the app's own
/// `Navigator`, inside [LeakSentry]. The badge stays in this widget's own
/// `Stack`, but the screen is a page of the app's navigator, found below this
/// widget, so dialogs, the back button and text selection work in it. Without a
/// navigator to put it on, it is shown over the app in a navigator of its own.
///
/// It shows nothing until there is a leak or a notice, so it costs an app that
/// has none nothing.
class LeakSentryOverlay extends StatefulWidget {
  const LeakSentryOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<LeakSentryOverlay> createState() => _LeakSentryOverlayState();
}

class _LeakSentryOverlayState extends State<LeakSentryOverlay> implements LeakSentryInternal {
  late final InternalLeakSentry _engine = InternalLeakSentry.instance;

  /// The tab the screen is open on in the navigator of its own, when there is
  /// no other navigator.
  LeakSentryTab? _ownNavigatorTab;

  @override
  void initState() {
    super.initState();
    _engine.screenOpener = _open;
  }

  @override
  void dispose() {
    if (_engine.screenOpener == _open) _engine.screenOpener = null;
    super.dispose();
  }

  Future<void> _open(LeakSentryTab tab) async {
    if (_engine.isScreenOpen || _ownNavigatorTab != null || !mounted) return;
    final navigator = _findNavigator();
    if (navigator == null) {
      setState(() => _ownNavigatorTab = tab);
      return;
    }
    await navigator.push(
      LeakSentryRoute<void>(
        engine: _engine,
        settings: const RouteSettings(name: '/leak_sentry'),
        builder: (_) => LeakSentryScreen.withEngine(engine: _engine, initialTab: tab),
      ),
    );
  }

  /// The first navigator below this widget: the app's, which is its child. It is looked for
  /// every time and not kept: a navigator that was kept would be held on to after the app
  /// that had it was replaced.
  NavigatorState? _findNavigator() {
    NavigatorState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is NavigatorState) {
        found = element.state as NavigatorState;
        return;
      }
      element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    final ownTab = _ownNavigatorTab;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: ListenableBuilder(
            listenable: Listenable.merge([engine.catalog, engine.notices, engine.screenOpen]),
            builder: (context, _) {
              // Nothing is shown in a release build that did not install LeakSentry: a resource that
              // was never closed is found there too, and it is not for the people using the app.
              if (engine.screenOpen.value || (engine.isReleaseBuild && !engine.isInstalled)) {
                return const SizedBox.shrink();
              }
              final leaks = engine.catalog.leakCount;
              final notice = engine.notices.value;
              final noticeText = notice == null ? null : _noticeText(engine, notice);
              if (leaks == 0 && noticeText == null) return const SizedBox.shrink();
              return _BadgeLayer(
                leaks: leaks,
                unread: engine.catalog.unreadCount,
                notice: noticeText,
                onOpenLeaks: () => _open(LeakSentryTab.leaks),
                onOpenScans: () => _open(LeakSentryTab.scans),
              );
            },
          ),
        ),
        if (ownTab != null)
          Positioned.fill(
            child: Navigator(
              onGenerateRoute: (_) => LeakSentryRoute<void>(
                engine: _engine,
                builder: (_) => LeakSentryScreen.withEngine(
                  engine: _engine,
                  initialTab: ownTab,
                  onClose: () => setState(() => _ownNavigatorTab = null),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// What the notice chip says, or null when there is nothing to say.
  static String? _noticeText(InternalLeakSentry engine, RetainedNotice notice) {
    switch (notice.kind) {
      case RetainedNoticeKind.allClear:
        return LeakSentryCopy.noticeAllClear;
      case RetainedNoticeKind.nothingOnRequest:
        return null;
      case RetainedNoticeKind.held:
        return switch (notice.reason) {
          BelowThresholdEvent() => LeakSentryCopy.noticeHeld(notice.objectCount, engine.config.retainedVisibleThreshold),
          DumpHappenedRecentlyEvent() => LeakSentryCopy.noticeRecent(notice.objectCount),
          DumpingDisabledEvent() => LeakSentryCopy.noticeSwitchedOff(notice.objectCount),
          _ => LeakSentryCopy.noticeFailed(notice.objectCount),
        };
    }
  }
}

/// The badge and the notice, in the corner. Nothing here needs a navigator, a
/// theme or a localization from the app: it sits above all of them.
class _BadgeLayer extends StatelessWidget {
  const _BadgeLayer({
    required this.leaks,
    required this.unread,
    required this.notice,
    required this.onOpenLeaks,
    required this.onOpenScans,
  });

  final int leaks;
  final int unread;
  final String? notice;
  final VoidCallback onOpenLeaks;
  final VoidCallback onOpenScans;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SafeArea(
        child: Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (notice != null) _NoticeChip(text: notice!, onTap: onOpenScans),
                if (notice != null && leaks > 0) const SizedBox(height: 8),
                if (leaks > 0) _LeakBadge(leaks: leaks, unread: unread, onTap: onOpenLeaks),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LeakBadge extends StatelessWidget {
  const _LeakBadge({required this.leaks, required this.unread, required this.onTap});

  final int leaks;
  final int unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${LeakSentryCopy.badgeLeaks(leaks)}. ${LeakSentryCopy.badgeOpenHint}',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('leak_sentry_overlay_badge'),
          borderRadius: BorderRadius.circular(28),
          onTap: onTap,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
                decoration: BoxDecoration(
                  color: LeakSentryColors.surface,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: unread > 0 ? LeakSentryColors.accentLine : LeakSentryColors.outline, width: 1.5),
                  boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 14, offset: Offset(0, 4))],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: LeakSentryColors.accentDeep),
                      child: const Icon(Icons.water_drop, size: 17, color: LeakSentryColors.accent),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      LeakSentryCopy.badgeLeaks(leaks),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: LeakSentryColors.text,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
              if (unread > 0)
                const Positioned(
                  top: -2,
                  right: -2,
                  child: DecoratedBox(
                    key: ValueKey('leak_sentry_overlay_unread'),
                    decoration: BoxDecoration(shape: BoxShape.circle, color: LeakSentryColors.accent),
                    child: SizedBox(width: 12, height: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeChip extends StatelessWidget {
  const _NoticeChip({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: text,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('leak_sentry_overlay_notice'),
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: LeakSentryColors.surfaceHigh,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: LeakSentryColors.outline),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.hourglass_top_rounded, size: 14, color: LeakSentryColors.accent),
                const SizedBox(width: 6),
                // It wraps, instead of running off the edge, when the text is large.
                Flexible(
                  child: Text(
                    text,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: LeakSentryColors.muted,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
