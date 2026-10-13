import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/analysis/node_status.dart';
import 'package:leak_sentry/analysis/trace_builder.dart';
import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/retaining_element.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/report_text.dart';
import 'package:leak_sentry/ui/trace_steps.dart';
import 'package:leak_sentry/ui/widgets/trace_timeline.dart';
import 'package:leak_sentry/utils/retaining_path_util.dart';

import '../helpers/leak_fixtures.dart';
import '../helpers/vm_fixtures.dart';

LeakInstance _withPath(String shape, {CreationSite? created = initStateSite, int count = 1, String type = '_PageThreeState'}) {
  final path = RetainingPathUtil.describe(VmFixture.load(shape).path);
  return LeakInstance(
    signature: 's',
    leakedType: type,
    count: count,
    firstSeen: at(0),
    lastSeen: at(0),
    creationSite: created,
    retainingPath: path,
    trace: TraceBuilder.structure(path),
  );
}

/// An instance whose path was worked out, as the analysis does it.
LeakInstance _traced(String shape, {String type = '_PageThreeState', String reason = 'why'}) {
  final path = RetainingPathUtil.describe(VmFixture.load(shape).path);
  return LeakInstance(
    signature: 's',
    leakedType: type,
    count: 1,
    firstSeen: at(0),
    lastSeen: at(0),
    creationSite: initStateSite,
    retainingPath: path,
    trace: TraceBuilder.build(path, leakedReason: reason),
  );
}

LeakGroup _group(List<LeakInstance> instances, {LeakKind kind = LeakKind.retained, String type = '_PageThreeState', String reason = 'why'}) =>
    leakGroup(kind: kind, type: type, reason: reason, instances: instances);

String _report(LeakGroup group) => buildLeakReport(group, now: at(5));

void main() {
  group('a report starts with where the object was created', () {
    test('and says what leaked, how many, and when it was last seen', () {
      final lines = _report(_group([leakInstance(count: 3)])).split('\n');

      expect(lines[0], 'LeakSentry report');
      expect(lines[1], '_PageThreeState · 3 objects · last seen 5 min ago');
      expect(lines[3], 'Created at: package:leak_entry_app/main.dart:196:11');
      expect(lines[4], '  _PageThreeState.initState');
    });

    test('before the path, however long it is', () {
      final text = _report(_group([_withPath('state_timer_closure')]));

      expect(text.indexOf('Created at:'), lessThan(text.indexOf('Path (from the root')));
    });

    test('says where an object was handed to the watcher, when that is all it knows', () {
      final text = _report(_group([leakInstance(created: null, watched: const CreationSite(uri: 'package:app/p.dart', member: 'build', line: 77, column: 5))]));

      expect(text, contains('Watched at: package:app/p.dart:77:5\n  build'));
      expect(text, isNot(contains('Created at')));
    });

    test('says why the creation site is not known, and where the class is declared', () {
      final text = _report(
        _group([
          leakInstance(created: null, gap: CreationSiteGap.onlyFrameworkFrames, declared: const CreationSite(uri: 'package:app/p.dart', member: '_S', line: 12, column: 1)),
        ]),
      );

      expect(text, contains('Creation site not recorded: ${LeakSentryCopy.creationGap(CreationSiteGap.onlyFrameworkFrames)}'));
      expect(text, contains('Class declared at: package:app/p.dart:12:1\n  _S'));
    });

    test('still says it is not recorded when it has no reason to give', () {
      final text = _report(_group([leakInstance(created: null)]));

      expect(text, contains('Creation site not recorded: ${LeakSentryCopy.creationUnknownNoReason}'));
    });

    test('a site without a member has no member line', () {
      final lines = _report(_group([leakInstance(created: const CreationSite(uri: 'package:app/p.dart', line: 3))])).split('\n');

      expect(lines[3], 'Created at: package:app/p.dart:3');
      expect(lines[4], startsWith('Path not traced'), reason: 'no indented member line between them');
    });
  });

  group('the path', () {
    test('goes from the root to the leaked object, each step with how it holds the next', () {
      final text = _report(_group([_withPath('state_listener_tearoff')]));

      expect(text, contains('Path (from the root to the leaked object)\n  Starts at: a static variable\n  1. record_vm_fixtures.dart .globalNotifier\n  2. ChangeNotifier ._listeners\n'));
      expect(text, contains('  5. _ListenerPageState (the leaked object)'));
    });

    test('says why there is none when there is none', () {
      final text = _report(_group([leakInstance()]));

      expect(text, contains('Path not traced: ${LeakSentryCopy.pathUnknown}'));
    });

    test('gives the reason it was not traced', () {
      final instance = LeakInstance(
        signature: 's',
        leakedType: '_PageThreeState',
        count: 1,
        firstSeen: at(0),
        lastSeen: at(0),
        creationSite: initStateSite,
        pathGap: RetainingPathGap.noVmService,
      );

      expect(_report(_group([instance])), contains('Path not traced: ${LeakSentryCopy.pathGap(RetainingPathGap.noVmService)}'));
    });

    test('says when the VM left steps out', () {
      const info = RetainingPathInfo(
        gcRootType: 'user global',
        hops: ['a', 'b'],
        elements: [
          RetainingElement(kind: RetainingElementKind.instance, className: 'Leaky'),
          RetainingElement(kind: RetainingElementKind.instance, className: 'Link', field: 'next'),
        ],
        totalLength: 60,
      );
      final instance = LeakInstance(
        signature: 's',
        leakedType: '_PageThreeState',
        count: 1,
        firstSeen: at(0),
        lastSeen: at(0),
        creationSite: initStateSite,
        retainingPath: info,
        trace: TraceBuilder.structure(info),
      );

      expect(_report(_group([instance])), contains('(58 more steps to the root)'));
    });
  });

  group('a trace as text', () {
    const trace = LeakTrace(
      gcRootType: 'user global',
      nodes: [
        TraceNode(
          kind: TraceNodeKind.staticHolder,
          name: '_Registry',
          status: NodeStatus.inUse,
          reference: TraceReference(kind: TraceReferenceKind.staticVariable, name: '.pages', genericName: 'pages', isSuspect: true),
        ),
        TraceNode(
          kind: TraceNodeKind.list,
          name: '_GrowableList',
          status: NodeStatus.unclear,
          reference: TraceReference(kind: TraceReferenceKind.listSlot, name: '[0]', genericName: '[x]'),
        ),
        TraceNode(kind: TraceNodeKind.instance, name: '_PageFiveState', status: NodeStatus.shouldBeGone),
      ],
    );

    test('says each step\'s status, and marks a likely cause', () {
      expect(describeTrace(trace), [
        'Starts at: a static variable',
        '1. _Registry .pages [in use] <- likely cause',
        '2. _GrowableList [0] [unclear]',
        '3. _PageFiveState [should be gone] (the leaked object)',
      ]);
    });

    test('says why a step is what it is, under it', () {
      const explained = LeakTrace(
        gcRootType: 'user global',
        nodes: [
          TraceNode(
            kind: TraceNodeKind.staticHolder,
            name: '_Registry',
            status: NodeStatus.inUse,
            note: 'A static variable lives as long as the app.',
            reference: TraceReference(kind: TraceReferenceKind.staticVariable, name: '.pages', genericName: 'pages', isSuspect: true),
          ),
          TraceNode(kind: TraceNodeKind.instance, name: '_PageFiveState', status: NodeStatus.shouldBeGone, note: 'Expected to be gone: it was disposed'),
        ],
      );

      expect(describeTrace(explained), [
        'Starts at: a static variable',
        '1. _Registry .pages [in use] <- likely cause',
        '   A static variable lives as long as the app.',
        '2. _PageFiveState [should be gone] (the leaked object)',
        '   Expected to be gone: it was disposed',
      ]);
    });

    test('has no status until someone has looked', () {
      const unlooked = LeakTrace(
        gcRootType: 'stack',
        nodes: [TraceNode(kind: TraceNodeKind.instance, name: 'Leaky')],
      );

      expect(describeTrace(unlooked), ['Starts at: a running function', '1. Leaky (the leaked object)']);
    });
  });

  group('a leak whose path was worked out', () {
    test('is called by its likely cause, says what it holds, and why each step is what it is', () {
      final text = _report(_group([_traced('state_static_registry', type: '_RegistryPageState', reason: 'it was disposed')], type: '_RegistryPageState'));

      final lines = text.split('\n');
      expect(lines[1], 'record_vm_fixtures.dart.topList · 1 object · last seen 5 min ago');
      expect(lines[2], 'Holds _RegistryPageState');
      expect(text, contains('''
Path (from the root to the leaked object)
  Starts at: a static variable
  1. record_vm_fixtures.dart .topList [in use] <- likely cause
     A static variable lives as long as the app.
  2. _GrowableList [1] [unclear] <- likely cause
  3. _RegistryPageState [should be gone] (the leaked object)
     Expected to be gone: it was disposed'''));
    });

    test('says what each kind of object it holds is, when it holds more than one', () {
      final text = _report(
        _group([
          _traced('state_static_registry', type: '_RegistryPageState'),
          _traced('animation_controller', type: 'AnimationController'),
        ]),
      );

      expect(text, contains('Holds _RegistryPageState and AnimationController'));
      expect(text, contains('Instance 1 of 2 · _RegistryPageState · 1 object'));
      expect(text, contains('Instance 2 of 2 · AnimationController · 1 object'));
    });

    test('says nothing of what it holds when no cause is known: the title is what it is', () {
      final lines = _report(_group([_withPath('static_class_field')])).split('\n');

      expect(lines[1], startsWith('_PageThreeState · '));
      expect(lines[2], '', reason: 'no line for what it holds');
    });

    test('says when LeakSentry itself holds it', () {
      final internal = LeakInstance(
        signature: 's',
        leakedType: '_PageThreeState',
        count: 1,
        firstSeen: at(0),
        lastSeen: at(0),
        creationSite: initStateSite,
        trace: const LeakTrace(
          gcRootType: 'user global',
          fingerprint: 'f',
          nodes: [
            TraceNode(
              kind: TraceNodeKind.staticHolder,
              name: 'Engine',
              library: 'package:leak_sentry/core/engine.dart',
              status: NodeStatus.inUse,
              reference: TraceReference(kind: TraceReferenceKind.staticVariable, name: '.page', genericName: 'page', isSuspect: true),
            ),
            TraceNode(kind: TraceNodeKind.instance, name: '_PageThreeState', status: NodeStatus.shouldBeGone),
          ],
        ),
      );

      final lines = _report(_group([internal])).split('\n');

      expect(lines[1], startsWith('Engine.page · '));
      expect(lines[2], 'Holds _PageThreeState');
      expect(lines[3], LeakSentryCopy.tagInternal);
    });
  });

  group('several instances', () {
    test('each says where it came from, and has its own path', () {
      final text = _report(
        _group([
          _withPath('static_class_field', count: 2),
          _withPath('state_static_registry', created: const CreationSite(uri: 'package:app/other.dart', member: 'make', line: 9, column: 3)),
        ]),
      );

      expect(text, contains('Instance 1 of 2 · _PageThreeState · 2 objects'));
      expect(text, contains('Instance 2 of 2 · _PageThreeState · 1 object'));
      expect(text, contains('Created at: package:app/other.dart:9:3'));
      expect('Created at:'.allMatches(text), hasLength(2));
      expect('Path (from the root'.allMatches(text), hasLength(2));
    });

    test('one instance has no heading', () {
      expect(_report(_group([leakInstance()])), isNot(contains('Instance 1 of')));
    });
  });

  group('a resource that was never closed', () {
    test('says where it was acquired and shows the stack, and has no path', () {
      final stack = StackTrace.fromString(
        '#0      PageFourState.initState (package:app/page_four.dart:12:5)\n'
        '#1      StatefulElement._firstBuild (package:flutter/src/widgets/framework.dart:5950:55)\n',
      );
      final instance = LeakInstance(
        signature: 's',
        leakedType: '_PageThreeState',
        count: 1,
        firstSeen: at(0),
        lastSeen: at(0),
        creationSite: const CreationSite(uri: 'package:app/page_four.dart', member: 'PageFourState.initState', line: 12, column: 5),
        acquiredAt: stack,
      );

      final text = _report(_group([instance], kind: LeakKind.resource, type: 'StreamController<int>', reason: 'PageFour.controller'));

      expect(text, contains('PageFour.controller · 1 object'));
      expect(text, contains('Acquired at: package:app/page_four.dart:12:5\n  PageFourState.initState'));
      expect(text, contains('Stack when it was acquired\n  #0      PageFourState.initState (package:app/page_four.dart:12:5)'));
      expect(text, isNot(contains('Path')));
    });

    test('shows no more than ten lines of the stack', () {
      final stack = StackTrace.fromString([for (var i = 0; i < 30; i++) '#$i      f$i (package:app/a.dart:$i:1)'].join('\n'));
      final instance = LeakInstance(signature: 's', leakedType: '_PageThreeState', count: 1, firstSeen: at(0), lastSeen: at(0), creationSite: initStateSite, acquiredAt: stack);

      final text = _report(_group([instance], kind: LeakKind.resource));

      expect('#'.allMatches(text).length, 10);
    });

    test('with no stack says only where, if it knows', () {
      final text = _report(_group([leakInstance()], kind: LeakKind.resource));

      expect(text, contains('Acquired at:'));
      expect(text, isNot(contains('Stack when')));
    });
  });

  group('as plain text', () {
    test('has none of the drawing characters of a terminal diagram', () {
      final text = _report(_group([_withPath('state_timer_closure'), leakInstance(created: null, gap: CreationSiteGap.web)]));

      expect(text, isNot(matches(RegExp('[│─┬┴├┤┌┐└┘╭╮╰╯]'))));
      expect(text, isNot(contains('~~~')));
      expect(text, isNot(contains('GC Root')));
    });

    test('ends without trailing blank lines', () {
      final text = _report(_group([leakInstance()]));

      expect(text, isNot(endsWith('\n')));
    });
  });

  group('the steps of the timeline', () {
    test('are the steps of the trace, with what is said under each', () {
      const trace = LeakTrace(
        gcRootType: 'user global',
        nodes: [
          TraceNode(
            kind: TraceNodeKind.staticHolder,
            name: '_Registry',
            library: 'package:app/registry.dart',
            status: NodeStatus.inUse,
            note: 'A static variable.',
            reference: TraceReference(kind: TraceReferenceKind.staticVariable, name: '.pages', genericName: 'pages', isSuspect: true),
          ),
          TraceNode(
            kind: TraceNodeKind.closure,
            name: 'main.<anonymous closure>',
            library: 'package:app/main.dart',
            declaredAt: CreationSite(uri: 'package:app/main.dart', line: 98),
            reference: TraceReference(kind: TraceReferenceKind.capturedVariable, name: 'captured variable', genericName: '<captured>'),
          ),
          TraceNode(kind: TraceNodeKind.instance, name: 'Leaky', status: NodeStatus.shouldBeGone),
        ],
      );

      final steps = timelineStepsOf(trace);

      expect(steps.map((step) => step.title), ['_Registry', 'main.<anonymous closure>', 'Leaky']);
      expect(steps[0].detail, 'package:app/registry.dart');
      expect(steps[0].status, NodeStatus.inUse);
      expect(steps[0].note, 'A static variable.');
      expect(steps[0].reference!.text, '.pages');
      expect(steps[0].reference!.isSuspect, isTrue);
      expect(steps[1].detail, 'written at lib/main.dart:98', reason: 'a closure says where it is written');
      expect(steps[1].reference!.isSuspect, isFalse);
      expect(steps[2].reference, isNull);
      expect(steps[2].status, NodeStatus.shouldBeGone);
    });

    test('says which likely cause to start with: the first one, and no other', () {
      const trace = LeakTrace(
        gcRootType: 'user global',
        nodes: [
          TraceNode(
            kind: TraceNodeKind.staticHolder,
            name: 'A',
            reference: TraceReference(kind: TraceReferenceKind.staticVariable, name: '.a', genericName: 'a'),
          ),
          TraceNode(
            kind: TraceNodeKind.instance,
            name: 'B',
            reference: TraceReference(kind: TraceReferenceKind.field, name: '.b', genericName: 'b', isSuspect: true),
          ),
          TraceNode(
            kind: TraceNodeKind.instance,
            name: 'C',
            reference: TraceReference(kind: TraceReferenceKind.field, name: '.c', genericName: 'c', isSuspect: true),
          ),
          TraceNode(kind: TraceNodeKind.instance, name: 'Leaky'),
        ],
      );

      final steps = timelineStepsOf(trace);

      expect(steps.map((step) => step.reference?.isSuspect), [false, true, true, null]);
      expect(steps.map((step) => step.reference?.isFirstSuspect), [false, true, false, null]);
    });

    test('says under the leaked object where it came from, when that is known', () {
      const trace = LeakTrace(
        gcRootType: 'user global',
        nodes: [
          TraceNode(kind: TraceNodeKind.instance, name: 'Holder', library: 'package:app/holder.dart', reference: TraceReference(kind: TraceReferenceKind.field, name: '.x', genericName: 'x')),
          TraceNode(kind: TraceNodeKind.instance, name: 'Leaky', library: 'package:app/leaky.dart'),
        ],
      );

      final without = timelineStepsOf(trace);
      final with_ = timelineStepsOf(trace, leakedAt: (label: 'Created at', site: initStateSite));

      expect(without.last.detail, 'package:app/leaky.dart');
      expect(with_.last.detail, 'created at lib/main.dart:196');
      expect(with_.first.detail, 'package:app/holder.dart', reason: 'only the leaked object says it');
    });

    test('a closure that does not know where it is written says what library it is in', () {
      const trace = LeakTrace(
        gcRootType: 'stack',
        nodes: [TraceNode(kind: TraceNodeKind.closure, name: 'f', library: 'package:app/main.dart')],
      );

      expect(timelineStepsOf(trace).single.detail, 'package:app/main.dart');
      expect(timelineStepsOf(trace).single, isA<TimelineStep>());
    });
  });
}
