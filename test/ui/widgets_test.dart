import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/node_status.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/format.dart';
import 'package:leak_sentry/ui/tokens.dart';
import 'package:leak_sentry/ui/widgets/count_badge.dart';
import 'package:leak_sentry/ui/widgets/empty_state.dart';
import 'package:leak_sentry/ui/widgets/leak_card.dart';
import 'package:leak_sentry/ui/widgets/section_card.dart';
import 'package:leak_sentry/ui/widgets/site_line.dart';
import 'package:leak_sentry/ui/widgets/status_pill.dart';
import 'package:leak_sentry/ui/widgets/tag_chip.dart';

import '../helpers/leak_fixtures.dart';
import '../helpers/pump_ui.dart';

/// The ways the screens are looked at that have to work: the usual, text scaled up
/// as a developer who needs it has it, and a narrow phone.
const _conditions = [(1.0, 400.0), (1.5, 400.0), (1.0, 320.0), (1.5, 320.0)];

BoxDecoration _decorationOf(WidgetTester tester, Finder within) =>
    tester.widget<DecoratedBox>(find.descendant(of: within, matching: find.byType(DecoratedBox)).first).decoration as BoxDecoration;

void main() {
  group('the count badge', () {
    testWidgets('shows how many objects, and 99+ beyond 99', (tester) async {
      await pumpUi(tester, const Column(children: [CountBadge(count: 7), CountBadge(count: 100)]));

      expect(find.text('7'), findsOneWidget);
      expect(find.text('99+'), findsOneWidget);
    });

    testWidgets('is a ring, filled with the accent while unread', (tester) async {
      await pumpUi(tester, const Column(children: [CountBadge(key: Key('unread'), count: 3, unread: true), CountBadge(key: Key('read'), count: 3)]));

      final unread = tester.widget<Container>(find.descendant(of: find.byKey(const Key('unread')), matching: find.byType(Container))).decoration as BoxDecoration;
      final read = tester.widget<Container>(find.descendant(of: find.byKey(const Key('read')), matching: find.byType(Container))).decoration as BoxDecoration;
      expect(unread.shape, BoxShape.circle);
      expect(unread.color, LeakSentryColors.accent);
      expect(read.shape, BoxShape.circle);
      expect(read.color, LeakSentryColors.surfaceHigh);
    });

    for (final (scale, width) in _conditions) {
      testWidgets('keeps its number inside at text scale $scale, $width wide', (tester) async {
        await pumpUi(tester, const Row(children: [CountBadge(count: 88, unread: true)]), textScale: scale, width: width);

        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(CountBadge)), const Size(44, 44));
      });
    }
  });

  group('the status pill', () {
    testWidgets('says in words what a step is', (tester) async {
      await pumpUi(tester, Column(children: [for (final status in NodeStatus.values) StatusPill(status)]));

      expect(find.text('In use'), findsOneWidget);
      expect(find.text('Should be gone'), findsOneWidget);
      expect(find.text('Unclear'), findsOneWidget);
    });

    testWidgets('has a colour of its own for each', (tester) async {
      await pumpUi(tester, Column(children: [for (final status in NodeStatus.values) StatusPill(status, key: ValueKey(status))]));

      final colours = {for (final status in NodeStatus.values) _decorationOf(tester, find.byKey(ValueKey(status))).color};
      expect(colours, hasLength(3));
      expect(_decorationOf(tester, find.byKey(const ValueKey(NodeStatus.shouldBeGone))).color, LeakSentryColors.dangerDeep);
    });
  });

  group('the tag chip', () {
    testWidgets('is a small outlined label', (tester) async {
      await pumpUi(tester, const Wrap(children: [TagChip.accent('NEW'), TagChip.caution('Resource'), TagChip('Held by LeakSentry')]));

      expect(find.text('NEW'), findsOneWidget);
      expect(find.text('Resource'), findsOneWidget);
      expect(find.text('Held by LeakSentry'), findsOneWidget);
    });
  });

  group('the section card and the empty state', () {
    testWidgets('a card has a title and its content', (tester) async {
      await pumpUi(tester, const SectionCard(title: 'Where it was created', child: Text('content')));

      expect(find.text('Where it was created'), findsOneWidget);
      expect(find.text('content'), findsOneWidget);
    });

    testWidgets('a card needs no title', (tester) async {
      await pumpUi(tester, const SectionCard(child: Text('content')));

      expect(find.text('content'), findsOneWidget);
    });

    for (final (scale, width) in _conditions) {
      testWidgets('an empty state fits at text scale $scale, $width wide', (tester) async {
        await pumpUi(
          tester,
          const EmptyState(icon: Icons.check, title: LeakSentryCopy.leaksEmptyTitle, body: LeakSentryCopy.leaksEmptyBody),
          textScale: scale,
          width: width,
          scrollable: false,
        );

        expect(tester.takeException(), isNull);
        expect(find.text(LeakSentryCopy.leaksEmptyTitle), findsOneWidget);
      });
    }
  });

  group('a place in the source', () {
    testWidgets('is shown as a file and line, the member, and the package', (tester) async {
      await pumpUi(tester, const SiteLine(label: 'Created at', site: initStateSite));

      expect(find.text('Created at'), findsOneWidget);
      expect(find.text('lib/main.dart:196'), findsOneWidget);
      expect(find.text('_PageThreeState.initState'), findsOneWidget);
      expect(find.text('package:leak_entry_app'), findsOneWidget);
    });

    testWidgets('has no member line when it has no member', (tester) async {
      await pumpUi(tester, const SiteLine(label: 'Watched at', site: CreationSite(uri: 'package:app/p.dart', line: 3)));

      expect(find.text('lib/p.dart:3'), findsOneWidget);
      expect(find.textContaining('initState'), findsNothing);
    });

    testWidgets('copies the whole location when tapped, and says so', (tester) async {
      final copied = captureClipboard(tester);
      await pumpUi(tester, const SiteLine(label: 'Created at', site: initStateSite));

      await tester.tap(find.byType(SiteLine));
      await tester.pump();

      expect(copied, ['package:leak_entry_app/main.dart:196:11']);
      expect(find.text(LeakSentryCopy.locationCopied), findsOneWidget);
    });

    testWidgets('can be activated through accessibility too', (tester) async {
      final handle = tester.ensureSemantics();
      final copied = captureClipboard(tester);
      await pumpUi(tester, const SiteLine(label: 'Created at', site: initStateSite));

      tester.semantics.tap(find.semantics.byLabel(RegExp('Created at')));
      await tester.pump();

      expect(copied, ['package:leak_entry_app/main.dart:196:11']);
      handle.dispose();
    });

    testWidgets('is a button, and says what it is the place of', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpUi(tester, const SiteLine(label: 'Created at', site: initStateSite));

      expect(
        tester.getSemantics(find.byType(SiteLine)),
        matchesSemantics(
          isButton: true,
          hasTapAction: true,
          label: 'Created at package:leak_entry_app/main.dart:196:11',
          hint: LeakSentryCopy.tapToCopy,
        ),
      );
      handle.dispose();
    });

    for (final (scale, width) in _conditions) {
      testWidgets('fits at text scale $scale, $width wide', (tester) async {
        await pumpUi(
          tester,
          const SiteLine(
            label: 'Created at',
            site: CreationSite(
              uri: 'package:a_package_with_a_rather_long_name/some/deeply/nested/directory/a_long_file_name.dart',
              member: '_AVeryLongStateNameForTheTestState.initState',
              line: 12345,
              column: 67,
            ),
          ),
          textScale: scale,
          width: width,
        );

        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a pin is an icon and a place, and a missing place is flagged', (tester) async {
      await pumpUi(tester, const Column(children: [LocationPin(text: 'main.dart:196'), LocationPin(text: 'unknown', missing: true)]));

      expect(find.byIcon(Icons.place_outlined), findsOneWidget);
      expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
    });
  });

  group('how a place is drawn', () {
    testWidgets('where the object was created is bright, and a fallback is cautious', (tester) async {
      await pumpUi(
        tester,
        const Column(children: [LocationPin(text: 'real'), LocationPin(text: 'next best', fallback: true), LocationPin(text: 'unknown', missing: true)]),
      );

      expect(tester.widget<Text>(find.text('real')).style!.color, LeakSentryColors.text);
      expect(tester.widget<Text>(find.text('next best')).style!.color, LeakSentryColors.caution);
      expect(tester.widget<Text>(find.text('unknown')).style!.color, LeakSentryColors.caution);
    });

    testWidgets('the member under a place is not dimmer than it needs to be, and the icon follows the place', (tester) async {
      await pumpUi(tester, const LocationPin(text: 'real', detail: 'Member.method'));
      expect(tester.widget<Text>(find.text(breakable('Member.method', after: '.'))).style!.color, LeakSentryColors.muted);
      expect(tester.widget<Icon>(find.byIcon(Icons.place_outlined)).color, LeakSentryColors.accent);

      await pumpUi(tester, const LocationPin(text: 'next best', fallback: true));
      expect(tester.widget<Icon>(find.byIcon(Icons.place_outlined)).color, LeakSentryColors.caution);

      await pumpUi(tester, const LocationPin(text: 'unknown', missing: true));
      expect(tester.widget<Icon>(find.byIcon(Icons.help_outline_rounded)).color, LeakSentryColors.caution);
    });

    testWidgets('a site line is mint where the object was created, and cautious as the next best place', (tester) async {
      await pumpUi(
        tester,
        const Column(
          children: [
            SiteLine(label: 'Created at', site: initStateSite),
            SiteLine(label: 'Class declared at', site: CreationSite(uri: 'package:app/p.dart', line: 3), isFallback: true),
          ],
        ),
      );

      expect(tester.widget<Text>(find.text('lib/main.dart:196')).style!.color, LeakSentryColors.accent);
      expect(tester.widget<Text>(find.text('lib/p.dart:3')).style!.color, LeakSentryColors.caution);
    });
  });

  group('a leak in the list', () {
    Future<void> pumpCard(
      WidgetTester tester,
      LeakGroup group, {
      VoidCallback? onTap,
      double textScale = 1.0,
      double width = 400,
      DateTime? now,
    }) => pumpUi(
      tester,
      LeakCard(group: group, now: now ?? at(11), onTap: onTap ?? () {}),
      textScale: textScale,
      width: width,
    );

    testWidgets('says what it is, how many objects, where it was created, and when it was seen', (tester) async {
      await pumpCard(tester, leakGroup(instances: [leakInstance(count: 3)]));

      expect(find.text('_PageThreeState'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('_PageThreeState received State#dispose() callback'), findsOneWidget, reason: 'why it was expected to be gone');
      expect(find.text('lib/main.dart:196'), findsOneWidget);
      expect(find.text(breakable('_PageThreeState.initState', after: '.')), findsOneWidget);
      expect(find.text('seen 11 min ago'), findsOneWidget, reason: 'how many is the circle\'s to say, not this line');
      expect(find.text('NEW'), findsOneWidget);
    });

    testWidgets('is called by its likely cause, and says what it holds instead of why it was expected to be gone', (tester) async {
      await pumpCard(tester, leakGroup(instances: [leakInstance(trace: causeTrace())]));

      expect(find.text(breakable('PageRegistry.pages', after: '.')), findsOneWidget);
      expect(find.text('Holds _PageThreeState'), findsOneWidget);
      expect(find.text('_PageThreeState received State#dispose() callback'), findsNothing);
      expect(find.text('lib/main.dart:196'), findsOneWidget, reason: 'where it was created is there all the same');
    });

    testWidgets('says what each kind of object it holds is', (tester) async {
      await pumpCard(
        tester,
        leakGroup(
          instances: [
            leakInstance(signature: 'a', trace: causeTrace()),
            leakInstance(signature: 'b', type: 'AnimationController', trace: causeTrace()),
            leakInstance(signature: 'c', type: 'ValueNotifier<int>', trace: causeTrace()),
            leakInstance(signature: 'd', type: 'Route<void>', trace: causeTrace()),
          ],
        ),
      );

      expect(find.text('Holds _PageThreeState, AnimationController and\u00A02 more'), findsOneWidget);
    });

    testWidgets('says when LeakSentry itself holds it', (tester) async {
      await pumpCard(tester, leakGroup(instances: [leakInstance(trace: causeTrace(internal: true))]));

      expect(find.text(LeakSentryCopy.tagInternal), findsOneWidget);
    });

    testWidgets('has no such tag when the app holds it', (tester) async {
      await pumpCard(tester, leakGroup(instances: [leakInstance(trace: causeTrace())]));

      expect(find.text(LeakSentryCopy.tagInternal), findsNothing);
    });

    testWidgets('puts the NEW tag with the time it was seen, so that the title has the whole width', (tester) async {
      await pumpCard(tester, leakGroup());

      final newTag = tester.getCenter(find.text('NEW'));
      final seen = tester.getCenter(find.text('seen 11 min ago'));
      final title = tester.getCenter(find.text('_PageThreeState'));
      expect(newTag.dy, closeTo(seen.dy, 2), reason: 'on the same line');
      expect(newTag.dx, lessThan(seen.dx));
      expect(newTag.dy, greaterThan(title.dy), reason: 'below the title, not beside it');
    });

    testWidgets('tells how many other places the leak came from in words', (tester) async {
      await pumpCard(
        tester,
        leakGroup(
          instances: [
            leakInstance(signature: 'a', minute: 9),
            leakInstance(signature: 'b', minute: 5, created: const CreationSite(uri: 'package:app/o.dart', member: 'make', line: 9)),
          ],
        ),
      );

      expect(find.textContaining('+1 more'), findsOneWidget);
    });

    testWidgets('draws the place in the cautious colour when it is not where the object was created', (tester) async {
      await pumpCard(tester, leakGroup(instances: [leakInstance(created: null, declared: const CreationSite(uri: 'package:app/p.dart', member: '_S', line: 12))]));

      expect(tester.widget<Text>(find.text('class declared at lib/p.dart:12')).style!.color, LeakSentryColors.caution);
    });

    testWidgets('draws where it was created in the colour of text that matters', (tester) async {
      await pumpCard(tester, leakGroup());

      expect(tester.widget<Text>(find.text('lib/main.dart:196')).style!.color, LeakSentryColors.text);
    });

    testWidgets('has no NEW tag once it has been opened', (tester) async {
      await pumpCard(tester, leakGroup(unread: false));

      expect(find.text('NEW'), findsNothing);
    });

    testWidgets('does not say how many times it was found when that was once', (tester) async {
      await pumpCard(tester, leakGroup());

      expect(find.text('seen 11 min ago'), findsOneWidget);
    });

    testWidgets('says that the creation site is not known, when it is not', (tester) async {
      await pumpCard(tester, leakGroup(instances: [leakInstance(created: null, gap: CreationSiteGap.onlyFrameworkFrames)]));

      expect(find.text(LeakSentryCopy.creationUnknown), findsOneWidget);
      expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
    });

    testWidgets('says where the class is declared, when that is all it knows', (tester) async {
      await pumpCard(
        tester,
        leakGroup(
          instances: [
            leakInstance(created: null, gap: CreationSiteGap.onlyFrameworkFrames, declared: const CreationSite(uri: 'package:app/p.dart', member: '_S', line: 12)),
          ],
        ),
      );

      expect(find.text('class declared at lib/p.dart:12'), findsOneWidget);
      expect(find.text('_S'), findsOneWidget);
      expect(find.text(LeakSentryCopy.creationUnknown), findsNothing);
    });

    testWidgets('says where an object was handed to the watcher, when that is all it knows', (tester) async {
      await pumpCard(
        tester,
        leakGroup(instances: [leakInstance(created: null, watched: const CreationSite(uri: 'package:app/p.dart', member: 'build', line: 77))]),
      );

      expect(find.text('watched at lib/p.dart:77'), findsOneWidget);
      expect(find.text('build'), findsOneWidget);
    });

    testWidgets('says how many other places it came from', (tester) async {
      await pumpCard(
        tester,
        leakGroup(
          instances: [
            leakInstance(signature: 'a', minute: 9, created: initStateSite),
            leakInstance(signature: 'b', minute: 5, created: const CreationSite(uri: 'package:app/o.dart', member: 'make', line: 9)),
            leakInstance(signature: 'c', minute: 3, created: const CreationSite(uri: 'package:app/q.dart', member: 'make', line: 1)),
          ],
        ),
      );

      expect(find.textContaining('+2'), findsOneWidget);
    });

    testWidgets('a resource says it was never closed, and where it was acquired', (tester) async {
      await pumpCard(tester, leakGroup(kind: LeakKind.resource, type: 'StreamController<int>', reason: 'PageFour.controller'));

      expect(find.text(LeakSentryCopy.resourceNeverClosed), findsOneWidget);
      expect(find.text(LeakSentryCopy.tagResource), findsOneWidget);
      expect(find.text(breakable('PageFour.controller', after: '.')), findsNWidgets(1), reason: 'the title of a resource is its label');
      expect(find.textContaining('lib/main.dart:196'), findsOneWidget);
    });

    testWidgets('can be tapped', (tester) async {
      var taps = 0;
      await pumpCard(tester, leakGroup(), onTap: () => taps++);

      await tester.tap(find.byType(LeakCard));

      expect(taps, 1);
    });

    for (final (scale, width) in _conditions) {
      testWidgets('fits at text scale $scale, $width wide, with long names', (tester) async {
        await pumpCard(
          tester,
          leakGroup(
            type: '_AnExtremelyLongNamedStateClassForTestingState',
            instances: [
              leakInstance(
                count: 1234,
                created: const CreationSite(
                  uri: 'package:a_package_with_a_rather_long_name/some/nested/directory/a_long_file_name.dart',
                  member: '_AnExtremelyLongNamedStateClassForTestingState.initState',
                  line: 12345,
                ),
              ),
            ],
          ),
          textScale: scale,
          width: width,
        );

        expect(tester.takeException(), isNull);
      });

      testWidgets('fits at text scale $scale, $width wide, with a long cause, several types and the internal tag', (tester) async {
        await pumpCard(
          tester,
          leakGroup(
            instances: [
              for (final type in const ['_AnExtremelyLongNamedStateClassForTestingState', 'AnotherVeryLongNamedAnimationController', 'Third'])
                leakInstance(
                  signature: type,
                  type: type,
                  trace: causeTrace(holder: 'AVeryLongNamedRegistryThatHoldsEverything', variable: 'aVariableWithAVeryLongNameIndeed', internal: true),
                ),
            ],
          ),
          textScale: scale,
          width: width,
        );

        expect(tester.takeException(), isNull);
        expect(find.text(LeakSentryCopy.tagInternal), findsOneWidget);
      });
    }
  });
}
