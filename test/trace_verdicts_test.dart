import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/analysis/node_status.dart';
import 'package:leak_sentry/analysis/object_inspectors.dart';
import 'package:leak_sentry/analysis/trace_builder.dart';
import 'package:leak_sentry/models/field_facts.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/retaining_element.dart';

/// Says what each step of a path is, by a letter per step from the root down: `E` is
/// in use, `S` should be gone, `U` is not said. The steps are told apart by their
/// names, so a path given to it must not have two steps of one name.
class _Spec implements NodeInspector {
  _Spec(this.letters, RetainingPathInfo path)
    : _names = [for (final node in TraceBuilder.structure(path)!.nodes) node.name] {
    assert(_names.toSet().length == _names.length, 'two steps are called the same: $_names');
    assert(letters.length == _names.length, '$letters has a letter too many or few for $_names');
  }

  final String letters;
  final List<String> _names;

  @override
  NodeFinding? inspect(InspectedNode node) => switch (letters[_names.indexOf(node.node.name)]) {
    'E' => const NodeFinding.inUse('spec says in use'),
    'S' => const NodeFinding.shouldBeGone('spec says gone'),
    _ => null,
  };
}

/// Says one thing about the step called [name], and nothing about any other.
class _Says implements NodeInspector {
  const _Says(this.name, this.finding);

  final String name;
  final NodeFinding finding;

  @override
  NodeFinding? inspect(InspectedNode node) => node.node.name == name ? finding : null;
}

/// A path of [count] objects the way the VM lists it, the leaked one first: `N0` is
/// the one nearest the root, `N{count - 1}` is the leaked one, and each holds the next
/// through its field `f<its number>`.
RetainingPathInfo _path(int count, {int firstHash = 100}) => RetainingPathInfo(
  gcRootType: 'user global',
  hops: List.filled(count, 'hop'),
  elements: [
    for (var i = count - 1; i >= 0; i--)
      RetainingElement(
        kind: RetainingElementKind.instance,
        className: 'N$i',
        libraryUri: 'package:app/n$i.dart',
        identityHash: firstHash + i,
        objectId: 'objects/$i',
        field: i == count - 1 ? null : 'f$i',
      ),
  ],
);

/// The trace of a path of [letters].length steps, told by the letters what each is.
LeakTrace _build(String letters) {
  final path = _path(letters.length);
  return TraceBuilder.build(path, structural: [_Spec(letters, path)], fields: const [])!;
}

/// What each step came to be, as letters: `E` in use, `S` should be gone, `U` unclear.
String _statuses(LeakTrace trace) => [
  for (final node in trace.nodes)
    switch (node.status!) {
      NodeStatus.inUse => 'E',
      NodeStatus.shouldBeGone => 'S',
      NodeStatus.unclear => 'U',
    },
].join();

/// Whether each reference of the trace is a likely cause, in order. The leaked
/// object holds nothing, so it has none.
List<bool> _suspects(LeakTrace trace) => [
  for (final node in trace.nodes)
    if (node.reference != null) node.reference!.isSuspect,
];

String _randomLetters(Random random, int length) =>
    String.fromCharCodes([for (var i = 0; i < length; i++) 'EUS'.codeUnitAt(random.nextInt(3))]);

void main() {
  group('what each step is, once what is known about the others is counted', () {
    test('the leaked object is the one that should be gone, whatever else is known', () {
      expect(_statuses(_build('U')), 'S');
      expect(_statuses(_build('S')), 'S');
      expect(_statuses(_build('UU')), 'US');
      expect(_statuses(_build('UUUS')), 'UUUS');
    });

    test('a leaked object that is also said to be in use should be gone, and the conflict is told', () {
      final trace = _build('UE');

      expect(_statuses(trace), 'US');
      expect(trace.nodes.last.note, 'This is the object that should be gone. Conflicts with spec says in use');
    });

    test('what holds something that is in use is in use', () {
      expect(_statuses(_build('UUEUS')), 'EEEUS');
      expect(_statuses(_build('UEUUS')), 'EEUUS');
    });

    test('and the note names the step below that made it so', () {
      final trace = _build('UUEUS');

      expect(trace.nodes[0].note, 'N2 below it is in use.');
      expect(trace.nodes[1].note, 'N2 below it is in use.');
      expect(trace.nodes[2].note, 'spec says in use');
    });

    test('the note names the nearest step below that is in use, not one further down', () {
      final trace = _build('UEEUS');

      expect(trace.nodes[0].note, 'N1 below it is in use.');
      expect(trace.nodes[1].note, 'N2 below it is in use, and spec says in use');
      expect(trace.nodes[2].note, 'spec says in use');
    });

    test('a step that is in use, above one that is too, says both', () {
      expect(_build('EUEUS').nodes[0].note, 'N2 below it is in use, and spec says in use');
    });

    test('what a leak holds is a leak', () {
      expect(_statuses(_build('USUUS')), 'USSSS');
      expect(_statuses(_build('UUSUUUS')), 'UUSSSSS');
    });

    test('and the note names the step above that made it so', () {
      final trace = _build('USUUS');

      expect(trace.nodes[2].note, 'N1 above it should be gone.');
      expect(trace.nodes[3].note, 'N1 above it should be gone.');
    });

    test('a step that should be gone, below one that should be too, says both', () {
      final trace = _build('USSUS');

      expect(trace.nodes[2].note, 'N1 above it should be gone, and spec says gone');
      expect(trace.nodes[3].note, 'N2 above it should be gone.');
    });

    test('a step in use below one that should be gone puts the start of the leak lower, and the conflict is told', () {
      final trace = _build('USEUS');

      expect(_statuses(trace), 'EEEUS');
      expect(trace.nodes[1].note, 'N2 below it is in use. Conflicts with spec says gone');
    });

    test('between a step in use and a step that should be gone, what is not said stays unclear', () {
      expect(_statuses(_build('EUUUS')), 'EUUUS');
      expect(_statuses(_build('EEUSUS')), 'EEUSSS');
    });

    test('a path of two is the leaked object and what holds it', () {
      expect(_statuses(_build('ES')), 'ES');
      expect(_statuses(_build('US')), 'US');
      expect(_statuses(_build('SS')), 'SS');
    });

    test('inspectors that disagree about a step keep it in use, and the conflict is told', () {
      final trace = TraceBuilder.build(
        _path(3),
        structural: const [
          _Says('N1', NodeFinding.inUse('it is alive')),
          _Says('N1', NodeFinding.shouldBeGone('it is disposed')),
        ],
        fields: const [],
      )!;

      expect(trace.nodes[1].status, NodeStatus.inUse);
      expect(trace.nodes[1].note, 'it is alive Conflicts with it is disposed');
    });

    test('inspectors that disagree about the leaked object say it should be gone, and the conflict is told', () {
      final trace = TraceBuilder.build(
        _path(2),
        structural: const [
          _Says('N1', NodeFinding.inUse('it is alive')),
          _Says('N1', NodeFinding.shouldBeGone('it is disposed')),
        ],
        fields: const [],
      )!;

      expect(trace.nodes[1].status, NodeStatus.shouldBeGone);
      expect(trace.nodes[1].note, 'it is disposed Conflicts with it is alive');
    });

    test('inspectors that agree a step should be gone have what they say joined', () {
      final trace = TraceBuilder.build(
        _path(3),
        structural: const [_Says('N1', NodeFinding.shouldBeGone('closed')), _Says('N1', NodeFinding.shouldBeGone('disposed'))],
        fields: const [],
      )!;

      expect(trace.nodes[1].note, 'closed disposed');
    });

    test('inspectors that agree have what they say joined', () {
      final trace = TraceBuilder.build(
        _path(3),
        structural: const [_Says('N1', NodeFinding.inUse('first')), _Says('N1', NodeFinding.inUse('second'))],
        fields: const [],
      )!;

      expect(trace.nodes[1].note, 'first second');
    });

    test('inspectors that say a step should be gone, and nothing is in use, leave it so', () {
      final trace = TraceBuilder.build(
        _path(4),
        structural: const [_Says('N1', NodeFinding.shouldBeGone('closed'))],
        fields: const [],
      )!;

      expect(_statuses(trace), 'USSS');
      expect(trace.nodes[1].note, 'closed');
      expect(trace.nodes[2].note, 'N1 above it should be gone.');
    });

    test('has no trace for a path with nothing in it', () {
      expect(TraceBuilder.build(const RetainingPathInfo(gcRootType: 'stack', hops: []), structural: const [], fields: const []), isNull);
    });
  });

  group('which references are likely causes', () {
    test('every reference of a step that is not known', () {
      expect(_suspects(_build('UUUS')), [true, true, true]);
    });

    test('the reference where what is in use meets what is not', () {
      expect(_suspects(_build('EEUS')), [false, true, true]);
      expect(_suspects(_build('EEES')), [false, false, true]);
    });

    test('the last reference before the leaked object, even when its step is in use', () {
      expect(_suspects(_build('ES')), [true]);
      expect(_suspects(_build('UES')), [false, true]);
    });

    test('never a reference of a step that should be gone: that is past the cause', () {
      expect(_suspects(_build('USUUS')), [true, false, false, false]);
      expect(_suspects(_build('EUSSS')), [true, true, false, false]);
    });

    test('the title of a leak is its first likely cause, the class that holds it and how', () {
      final trace = _build('EEUS');

      expect(trace.title, 'N1.f1');
      expect(trace.suspects.map((suspect) => suspect.node.name), ['N1', 'N2']);
    });

    test('a leaked object alone has no reference, so no likely cause and no title', () {
      final trace = _build('S');

      expect(trace.suspects, isEmpty);
      expect(trace.title, isNull);
    });
  });

  group('every trace has the shape the propagation gives it', () {
    test('in use, then unclear, then should be gone, whatever the inspectors said', () {
      final random = Random(20261012);
      final shape = RegExp(r'^E*U*S+$');
      for (var run = 0; run < 400; run++) {
        final letters = _randomLetters(random, 1 + random.nextInt(12));

        final result = _statuses(_build(letters));

        expect(shape.hasMatch(result), isTrue, reason: '$letters became $result');
        expect(result.length, letters.length);
      }
    });

    test('and nothing that was said is turned round, except where it could not all be true', () {
      final random = Random(1012);
      for (var run = 0; run < 400; run++) {
        final letters = _randomLetters(random, 1 + random.nextInt(12));

        final result = _statuses(_build(letters));

        // A step that was said to be in use stays in use unless it is the leaked object;
        // one said to be gone stays so unless a step in use is below it.
        final lastInUse = letters.lastIndexOf('E');
        for (var i = 0; i < letters.length; i++) {
          if (letters[i] == 'E' && i != letters.length - 1) expect(result[i], 'E', reason: '$letters became $result, at $i');
          if (letters[i] == 'S' && i > lastInUse) expect(result[i], 'S', reason: '$letters became $result, at $i');
        }
        expect(result.endsWith('S'), isTrue, reason: letters);
      }
    });

    test('and a reference is a likely cause by the rule, whatever the inspectors said', () {
      final random = Random(7);
      for (var run = 0; run < 400; run++) {
        final length = 2 + random.nextInt(10);
        final letters = _randomLetters(random, length);

        final trace = _build(letters);
        final result = _statuses(trace);

        for (var i = 0; i < length - 1; i++) {
          final expected = switch (result[i]) {
            'U' => true,
            'E' => i == length - 2 || result[i + 1] != 'E',
            _ => false,
          };
          expect(trace.nodes[i].reference!.isSuspect, expected, reason: '$letters became $result, at $i');
        }
      }
    });
  });

  group('the fingerprint of a leak', () {
    LeakTrace traceOf(RetainingPathInfo path, String letters, {Map<String, FieldFacts> facts = const {}}) =>
        TraceBuilder.build(path, structural: [_Spec(letters, path)], fields: fieldInspectors, facts: facts)!;

    RetainingPathInfo held(String holder, String variable) => RetainingPathInfo(
      gcRootType: 'user global',
      hops: const ['a', 'b'],
      elements: [
        const RetainingElement(kind: RetainingElementKind.instance, className: 'Leaky', libraryUri: 'package:app/leaky.dart'),
        RetainingElement(
          kind: RetainingElementKind.staticField,
          className: holder,
          field: variable,
          libraryUri: 'package:app/$holder.dart',
        ),
      ],
    );

    test('is the same for the same leak found again', () {
      expect(traceOf(_path(4), 'EUUS').fingerprint, traceOf(_path(4), 'EUUS').fingerprint);
    });

    test('does not change with the addresses of the objects', () {
      expect(traceOf(_path(4, firstHash: 100), 'EUUS').fingerprint, traceOf(_path(4, firstHash: 9000), 'EUUS').fingerprint);
    });

    test('does not change with the slot of a list, or the key of a map', () {
      RetainingPathInfo through(int slot, String key) => RetainingPathInfo(
        gcRootType: 'user global',
        hops: const ['a', 'b', 'c', 'd'],
        elements: [
          const RetainingElement(kind: RetainingElementKind.instance, className: 'Leaky', libraryUri: 'package:app/leaky.dart'),
          RetainingElement(kind: RetainingElementKind.list, className: '_List', index: slot, libraryUri: 'dart:core'),
          RetainingElement(
            kind: RetainingElementKind.map,
            className: '_Map',
            mapKey: key,
            mapKeyIsText: true,
            libraryUri: 'dart:core',
          ),
          const RetainingElement(
            kind: RetainingElementKind.staticField,
            className: 'Registry',
            field: 'cache',
            libraryUri: 'package:app/registry.dart',
          ),
        ],
      );

      final first = traceOf(through(0, 'a'), 'EUUS').fingerprint;

      expect(traceOf(through(41, 'zzz'), 'EUUS').fingerprint, first);
      expect(first, 'package:app/registry.dart:Registry:cache|dart:core:_Map:{key}|dart:core:_List:[x]');
    });

    test('is different when another variable holds it', () {
      expect(traceOf(held('Registry', 'pages'), 'ES').fingerprint, isNot(traceOf(held('Registry', 'cache'), 'ES').fingerprint));
    });

    test('is different when another class holds it', () {
      expect(traceOf(held('Registry', 'pages'), 'ES').fingerprint, isNot(traceOf(held('Cache', 'pages'), 'ES').fingerprint));
    });

    test('is the same whether or not the VM could say what is in the fields', () {
      final path = _path(4);
      final facts = {
        'objects/1': const FieldFacts(
          declaringClasses: {'ChangeNotifier'},
          values: {'ChangeNotifier._debugDisposed': 'false'},
        ),
        'objects/2': const FieldFacts(declaringClasses: {'State'}, values: {'State._element': 'null'}),
      };

      final without = traceOf(path, 'EUUS');
      final withFacts = traceOf(path, 'EUUS', facts: facts);

      expect(withFacts.fingerprint, without.fingerprint);
      expect(_statuses(without), 'EUUS');
      expect(_statuses(withFacts), 'EESS', reason: 'the facts did change what the timeline shows');
    });

    test('is made of the likely causes, and can be read', () {
      expect(
        traceOf(_path(4), 'EUUS').fingerprint,
        'package:app/n0.dart:N0:f0|package:app/n1.dart:N1:f1|package:app/n2.dart:N2:f2',
      );
    });

    test('is made of the leaked object when nothing holds it by a likely cause', () {
      final single = TraceBuilder.build(_path(1), structural: const [], fields: const [])!;

      expect(single.fingerprint, 'leaked:package:app/n0.dart:N0');
    });
  });

  group('what the VM is asked about', () {
    test('the steps that may be a State, an Element, a Route or a ChangeNotifier, nearest the leak first', () {
      final trace = TraceBuilder.build(_path(5), structural: const [], fields: const [])!;

      expect(TraceBuilder.objectsToInspect(trace), ['objects/3', 'objects/2', 'objects/1', 'objects/0']);
    });

    test('never the leaked object, a class, a list, a closure, or what Dart owns', () {
      const path = RetainingPathInfo(
        gcRootType: 'user global',
        hops: ['a', 'b', 'c', 'd', 'e', 'f'],
        elements: [
          RetainingElement(kind: RetainingElementKind.instance, className: 'Leaky', objectId: 'leaked'),
          RetainingElement(kind: RetainingElementKind.closure, function: 'f', objectId: 'closure', field: '_context'),
          RetainingElement(kind: RetainingElementKind.list, className: '_List', objectId: 'list', index: 0, libraryUri: 'dart:core'),
          RetainingElement(
            kind: RetainingElementKind.instance,
            className: '_Timer',
            objectId: 'timer',
            field: '_callback',
            libraryUri: 'dart:isolate',
          ),
          RetainingElement(
            kind: RetainingElementKind.instance,
            className: 'Holder',
            objectId: 'holder',
            field: 'x',
            libraryUri: 'package:app/h.dart',
          ),
          RetainingElement(kind: RetainingElementKind.staticField, className: 'Root', field: 'r', objectId: 'static'),
        ],
      );

      expect(TraceBuilder.objectsToInspect(TraceBuilder.structure(path)!), ['holder']);
    });

    test('no more of them than it is told to', () {
      final trace = TraceBuilder.build(_path(12), structural: const [], fields: const [])!;

      expect(TraceBuilder.objectsToInspect(trace, limit: 3), ['objects/10', 'objects/9', 'objects/8']);
      expect(TraceBuilder.objectsToInspect(trace), hasLength(11));
    });
  });
}
