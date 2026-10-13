import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/node_status.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/format.dart';
import 'package:leak_sentry/ui/tokens.dart';
import 'package:leak_sentry/ui/widgets/status_pill.dart';
import 'package:leak_sentry/ui/widgets/trace_timeline.dart';

import '../helpers/pump_ui.dart';

const _steps = [
  TimelineStep(
    title: '_Registry',
    detail: 'package:leak_entry_app/main.dart',
    status: NodeStatus.inUse,
    note: 'A static variable lives as long as the app.',
    reference: TimelineReference('.pages', isSuspect: true),
  ),
  TimelineStep(title: '_GrowableList', status: NodeStatus.unclear, reference: TimelineReference('[x]')),
  TimelineStep(
    title: '_PageFiveState',
    status: NodeStatus.shouldBeGone,
    note: 'Expected to be gone: the State was disposed.',
  ),
];

/// The rail painters of the rows of the timeline, which are the only custom painters in it.
Finder get _rails => find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is RailPainter);

RenderObject _rail(WidgetTester tester, int index) => tester.renderObject(_rails.at(index));

void main() {
  group('the timeline of a path', () {
    testWidgets('lists every step, numbered, with its status', (tester) async {
      await pumpUi(tester, const TraceTimeline(steps: _steps));

      expect(find.text('_Registry'), findsOneWidget);
      expect(find.text('_GrowableList'), findsOneWidget);
      expect(find.text('_PageFiveState'), findsOneWidget);
      expect(['1', '2', '3'].map((n) => find.text(n).evaluate().length), [1, 1, 1]);
      expect(find.text(LeakSentryCopy.statusInUse), findsOneWidget);
      expect(find.text(LeakSentryCopy.statusUnclear), findsOneWidget);
      expect(find.text(LeakSentryCopy.statusShouldBeGone), findsOneWidget);
    });

    testWidgets('says where a step comes from, and why it is what it is', (tester) async {
      await pumpUi(tester, const TraceTimeline(steps: _steps));

      expect(find.text(breakable('package:leak_entry_app/main.dart', after: '/:')), findsOneWidget);
      expect(find.text('A static variable lives as long as the app.'), findsOneWidget);
      expect(find.text('Expected to be gone: the State was disposed.'), findsOneWidget);
    });

    testWidgets('highlights the reference that is a likely cause, and says so', (tester) async {
      await pumpUi(tester, const TraceTimeline(steps: _steps));

      expect(find.text('.pages'), findsOneWidget);
      expect(find.text(LeakSentryCopy.likelyCause), findsOneWidget);
      final highlight = tester.widget<DecoratedBox>(find.ancestor(of: find.text('.pages'), matching: find.byType(DecoratedBox)).first);
      expect((highlight.decoration as BoxDecoration).color, LeakSentryColors.dangerDeep);
    });

    testWidgets('names the first of the likely causes as the one to start with', (tester) async {
      await pumpUi(
        tester,
        const TraceTimeline(
          steps: [
            TimelineStep(title: 'A', reference: TimelineReference('.a', isSuspect: true, isFirstSuspect: true)),
            TimelineStep(title: 'B', reference: TimelineReference('.b', isSuspect: true)),
            TimelineStep(title: 'C'),
          ],
        ),
      );

      expect(find.text(LeakSentryCopy.startHere), findsOneWidget);
      expect(find.text(LeakSentryCopy.likelyCause), findsOneWidget, reason: 'the other one is a likely cause, not where to start');
      expect(tester.getTopLeft(find.text(LeakSentryCopy.startHere)).dy, lessThan(tester.getTopLeft(find.text(LeakSentryCopy.likelyCause)).dy));
    });

    testWidgets('shows a reference that is not a likely cause as plain text', (tester) async {
      await pumpUi(tester, const TraceTimeline(steps: _steps));

      expect(find.text('[x]'), findsOneWidget);
      expect(find.ancestor(of: find.text('[x]'), matching: find.byType(DecoratedBox)), findsNothing);
      expect(find.text(LeakSentryCopy.likelyCause), findsOneWidget, reason: 'only the one that is');
    });

    testWidgets('says what the path starts at, and how many steps the VM left out', (tester) async {
      await pumpUi(tester, TraceTimeline(steps: _steps, startsAt: LeakSentryCopy.startsAt('user global'), hiddenSteps: 52));

      expect(find.text('Starts at: a static variable'), findsOneWidget);
      expect(find.text('52 more steps to the root'), findsOneWidget);
    });

    testWidgets('says neither when there is nothing to say', (tester) async {
      await pumpUi(tester, const TraceTimeline(steps: _steps));

      expect(find.textContaining('Starts at'), findsNothing);
      expect(find.textContaining('more step'), findsNothing);
    });

    testWidgets('a step with no status has no pill', (tester) async {
      await pumpUi(tester, const TraceTimeline(steps: [TimelineStep(title: 'Closure')]));

      expect(find.text('Closure'), findsOneWidget);
      expect(find.byType(StatusPill), findsNothing);
    });

    testWidgets('a path of one step has no rail', (tester) async {
      await pumpUi(tester, const TraceTimeline(steps: [TimelineStep(title: 'Only', status: NodeStatus.shouldBeGone)]));

      expect(_rail(tester, 0), isNot(paints..line()..rrect()));
      expect(_rail(tester, 0), paintsNothing);
    });
  });

  group('the rail', () {
    testWidgets('is a thin slate line between steps that hold nothing suspect', (tester) async {
      await pumpUi(
        tester,
        const TraceTimeline(
          steps: [
            TimelineStep(title: 'A', reference: TimelineReference('.a')),
            TimelineStep(title: 'B'),
          ],
        ),
      );

      expect(_rail(tester, 0), paints..line(color: LeakSentryColors.outline, strokeWidth: 2));
      expect(_rail(tester, 0), isNot(paints..rrect()));
      expect(_rail(tester, 1), paints..line(color: LeakSentryColors.outline, strokeWidth: 2));
    });

    testWidgets('is a solid coral rail on a band where a likely cause is held', (tester) async {
      await pumpUi(tester, const TraceTimeline(steps: _steps));

      // The first step holds the suspect: below its dot the rail is solid coral on a band, and nothing above it.
      expect(_rail(tester, 0), paints..rrect(color: LeakSentryColors.dangerDeep)..rrect(color: LeakSentryColors.danger));
      expect(_rail(tester, 0), isNot(paints..line()));
      expect(_rail(tester, 0), isNot(paints..circle()), reason: 'no dashes and no dots: the suspect rail is drawn solid');
      // The second step receives it above its dot, where only a short stub of the band fits, and holds
      // a plain reference below.
      expect(_rail(tester, 1), paints..rrect(color: LeakSentryColors.dangerDeep)..line(color: LeakSentryColors.outline));
      // The last step has only the plain piece above its dot.
      expect(_rail(tester, 2), paints..line(color: LeakSentryColors.outline));
      expect(_rail(tester, 2), isNot(paints..rrect()));
    });

    testWidgets('is drawn again when what it holds changes', (tester) async {
      const plain = TraceTimeline(
        steps: [
          TimelineStep(title: 'A', reference: TimelineReference('.a')),
          TimelineStep(title: 'B'),
        ],
      );
      const suspect = TraceTimeline(
        steps: [
          TimelineStep(title: 'A', reference: TimelineReference('.a', isSuspect: true)),
          TimelineStep(title: 'B'),
        ],
      );
      await pumpUi(tester, plain);
      expect(_rail(tester, 0), isNot(paints..rrect()));

      await pumpUi(tester, suspect);

      expect(_rail(tester, 0), paints..rrect(color: LeakSentryColors.dangerDeep));
    });
  });

  group('the rail painter', () {
    test('is drawn again when a piece of the rail changes, and not when nothing does', () {
      const base = RailPainter(above: RailStyle.plain, below: RailStyle.plain);

      expect(base.shouldRepaint(const RailPainter(above: RailStyle.plain, below: RailStyle.plain)), isFalse);
      expect(base.shouldRepaint(const RailPainter(above: RailStyle.suspect, below: RailStyle.plain)), isTrue);
      expect(base.shouldRepaint(const RailPainter(above: RailStyle.plain, below: RailStyle.suspect)), isTrue);
      expect(base.shouldRepaint(const RailPainter(above: null, below: RailStyle.plain)), isTrue);
      expect(base.shouldRepaint(const RailPainter(above: RailStyle.plain, below: null)), isTrue);
    });
  });

  group('for a reader who cannot see it', () {
    testWidgets('each step says which one it is', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpUi(tester, const TraceTimeline(steps: _steps));

      expect(find.bySemanticsLabel(RegExp(r'^Step 1 of 3')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Step 2 of 3')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Step 3 of 3')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the rail says nothing', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpUi(tester, const TraceTimeline(steps: _steps));

      expect(find.descendant(of: _rails, matching: find.byType(Semantics)), findsNothing);
      expect(find.ancestor(of: _rails.first, matching: find.byType(ExcludeSemantics)), findsWidgets);
      handle.dispose();
    });
  });

  group('whatever the screen', () {
    const conditions = [(1.0, 400.0), (1.5, 400.0), (1.0, 320.0), (1.5, 320.0)];
    final longSteps = [
      const TimelineStep(
        title: '_AnExtremelyLongNamedRegistryClassForTesting',
        detail: 'package:a_package_with_a_rather_long_name/some/nested/directory/a_long_file_name.dart',
        status: NodeStatus.inUse,
        note: 'A static variable lives as long as the app, and nothing LeakSentry knows of can have let go of it.',
        reference: TimelineReference('._anExtremelyLongNamedFieldHoldingTheListOfPages', isSuspect: true),
      ),
      const TimelineStep(title: '_GrowableList', status: NodeStatus.unclear, reference: TimelineReference('[x]')),
      const TimelineStep(title: '_AnExtremelyLongNamedStateClassForTestingState', status: NodeStatus.shouldBeGone),
    ];

    for (final (scale, width) in conditions) {
      testWidgets('fits at text scale $scale, $width wide', (tester) async {
        await pumpUi(tester, TraceTimeline(steps: longSteps, startsAt: 'Starts at: a static variable', hiddenSteps: 12), textScale: scale, width: width);

        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('keeps the dot of each step at its top, so the rail meets it, at any text scale', (tester) async {
      await pumpUi(tester, TraceTimeline(steps: longSteps), textScale: 1.5, width: 320);

      final dots = [for (final number in ['1', '2', '3']) tester.getTopLeft(find.text(number)).dy];
      expect(dots[0], lessThan(dots[1]));
      expect(dots[1], lessThan(dots[2]));
    });
  });
}
