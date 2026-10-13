import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/analysis/trace_builder.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/retaining_element.dart';
import 'package:leak_sentry/utils/retaining_path_util.dart';

import 'helpers/vm_fixtures.dart';

LeakTrace _trace(String shape) => TraceBuilder.structure(RetainingPathUtil.describe(VmFixture.load(shape).path))!;

/// Each step as it reads: `name` and, when it holds something, ` -> reference`.
List<String> _read(LeakTrace trace) => [
  for (final node in trace.nodes) node.reference == null ? node.name : '${node.name} ${node.reference!.name}',
];

const _file = 'record_vm_fixtures.dart';

void main() {
  group('from the root to the leaked object', () {
    test('a leaked object in a top-level list', () {
      expect(_read(_trace('static_top_level_list')), ['$_file .topList', '_GrowableList [0]', 'Leaky']);
    });

    test('a static member of a class is held by the class', () {
      expect(_read(_trace('static_class_field')), ['Holder .field', 'Leaky']);
    });

    test('a chain of fields names each field', () {
      expect(_read(_trace('instance_field_chain')), ['$_file .topLinks', 'Link .next', 'Link .next', 'Leaky']);
    });

    test('a map entry is written as a developer reads one: a text key in quotes', () {
      expect(_read(_trace('map_value')), ["$_file .topMap", "_Map ['k']", 'Leaky']);
    });

    test('a key that is an object is written by its class', () {
      expect(_read(_trace('map_key')), ['$_file .topMap', '_Map [Leaky]', 'Leaky']);
    });

    test('a closure holds what it captured directly, the context left out', () {
      expect(_read(_trace('closure_capture')), ['$_file .topClosure', 'buildClosure.<anonymous closure> captured variable', 'Leaky']);
    });

    test('a torn-off method holds its receiver', () {
      expect(_read(_trace('state_listener_tearoff')), [
        '$_file .globalNotifier',
        'ChangeNotifier ._listeners',
        '_List [0]',
        '_ListenerPageState._onChange receiver',
        '_ListenerPageState',
      ]);
    });

    test('a timer: the runtime\'s static heap, then the callback and the closures that wrap it', () {
      expect(_read(_trace('state_timer_closure')), [
        '_Timer ._heap',
        '_TimerHeap ._list',
        '_List [0]',
        '_Timer ._callback',
        for (var i = 0; i < 5; i++) '${_trace('state_timer_closure').nodes[4 + i].name} captured variable',
        '_TimerPageState',
      ]);
      expect(_trace('state_timer_closure').nodes, hasLength(10), reason: 'five contexts folded into five closures');
    });

    for (final (shape, slot, leaked) in const [
      ('state_static_registry', 1, '_RegistryPageState'),
      ('state_without_initstate', 2, '_NoInitPageState'),
      ('animation_controller', 3, 'AnimationController'),
      ('route_static', 4, 'MaterialPageRoute'),
    ]) {
      test('$shape: held by a list slot of a static variable', () {
        expect(_read(_trace(shape)), ['$_file .topList', '_GrowableList [$slot]', leaked]);
      });
    }

    test('the leaked object is the last step and holds nothing', () {
      for (final shape in VmFixture.shapes) {
        final nodes = _trace(shape).nodes;
        expect(nodes.last.reference, isNull, reason: shape);
        expect(nodes.take(nodes.length - 1).every((node) => node.reference != null), isTrue, reason: shape);
      }
    });
  });

  group('what each step knows about itself', () {
    test('a static holder is a holder, with where it is declared', () {
      final holder = _trace('static_class_field').nodes.first;

      expect(holder.kind, TraceNodeKind.staticHolder);
      expect(holder.library, endsWith(_file));
      expect(holder.declaredAt?.line, isPositive);
      expect(holder.reference!.kind, TraceReferenceKind.staticVariable);
    });

    test('the leaked object has its identity and the line of its class', () {
      final fixture = VmFixture.load('state_static_registry');
      final leaked = TraceBuilder.structure(RetainingPathUtil.describe(fixture.path))!.nodes.last;

      expect(leaked.identityHash, fixture.identityHash);
      expect(leaked.declaredAt?.member, '_RegistryPageState');
      expect(leaked.library, endsWith(_file));
    });

    test('a closure knows where it is written, and what library', () {
      final closure = _trace('closure_capture').nodes[1];

      expect(closure.kind, TraceNodeKind.closure);
      expect(closure.declaredAt?.line, isPositive);
      expect(closure.library, endsWith(_file));
    });

    test('a list and a map are known as such', () {
      expect(_trace('static_top_level_list').nodes[1].kind, TraceNodeKind.list);
      expect(_trace('map_value').nodes[1].kind, TraceNodeKind.map);
    });

    test('the references have a name that does not change from one run to the next', () {
      final generic = [for (final node in _trace('state_listener_tearoff').nodes) node.reference?.genericName];

      expect(generic, ['globalNotifier', '_listeners', '[x]', '<receiver>', null]);
      expect([for (final node in _trace('map_value').nodes) node.reference?.genericName], ['topMap', '{key}', null]);
      expect([for (final node in _trace('closure_capture').nodes) node.reference?.genericName], ['topClosure', '<captured>', null]);
    });

    test('no status, suspect or note is given before anyone has looked', () {
      for (final node in _trace('state_timer_closure').nodes) {
        expect(node.status, isNull);
        expect(node.note, isNull);
        expect(node.reference?.isSuspect ?? false, isFalse);
      }
    });
  });

  group('the path as the VM gave it', () {
    test('keeps the kind of root, and says how many steps were left out', () {
      const path = RetainingPathInfo(
        gcRootType: 'user global',
        hops: ['a', 'b'],
        elements: [
          RetainingElement(kind: RetainingElementKind.instance, className: 'Leaky'),
          RetainingElement(kind: RetainingElementKind.instance, className: 'Link', field: 'next'),
        ],
        totalLength: 50,
      );

      final trace = TraceBuilder.structure(path)!;

      expect(trace.gcRootType, 'user global');
      expect(trace.hiddenSteps, 48);
      expect(_read(trace), ['Link .next', 'Leaky']);
    });

    test('has no trace when there are no elements to build one from', () {
      expect(TraceBuilder.structure(const RetainingPathInfo(gcRootType: 'class table', hops: [])), isNull);
      expect(TraceBuilder.structure(const RetainingPathInfo(gcRootType: 'user global', hops: ['x'])), isNull);
    });

    test('a step whose field the VM did not name is still a step', () {
      const path = RetainingPathInfo(
        gcRootType: 'stack',
        hops: ['a', 'b'],
        elements: [
          RetainingElement(kind: RetainingElementKind.instance, className: 'Leaky'),
          RetainingElement(kind: RetainingElementKind.instance, className: 'Holder'),
        ],
      );

      expect(_read(TraceBuilder.structure(path)!), ['Holder .?', 'Leaky']);
      expect(TraceBuilder.structure(path)!.nodes.first.reference!.genericName, '<unknown>');
    });

    test('a context nothing folded away is a step of its own', () {
      const path = RetainingPathInfo(
        gcRootType: 'stack',
        hops: ['a', 'b', 'c'],
        elements: [
          RetainingElement(kind: RetainingElementKind.instance, className: 'Leaky'),
          RetainingElement(kind: RetainingElementKind.context, index: 0),
          RetainingElement(kind: RetainingElementKind.instance, className: 'Holder', field: 'scope'),
        ],
      );

      expect(_read(TraceBuilder.structure(path)!), ['Holder .scope', 'captured variables captured variable', 'Leaky']);
    });

    test('a closure that is the leaked object holds nothing', () {
      const path = RetainingPathInfo(
        gcRootType: 'stack',
        hops: ['a'],
        elements: [RetainingElement(kind: RetainingElementKind.closure, function: 'main.<anonymous closure>')],
      );

      final trace = TraceBuilder.structure(path)!;

      expect(_read(trace), ['main.<anonymous closure>']);
      expect(trace.nodes.single.kind, TraceNodeKind.closure);
    });

    test('a closure with no name is still called one', () {
      const path = RetainingPathInfo(
        gcRootType: 'stack',
        hops: ['a', 'b'],
        elements: [
          RetainingElement(kind: RetainingElementKind.instance, className: 'Leaky'),
          RetainingElement(kind: RetainingElementKind.closure),
        ],
      );

      expect(TraceBuilder.structure(path)!.nodes.first.name, 'closure');
    });

    test('a top-level variable whose library is not known is named for a library', () {
      const path = RetainingPathInfo(
        gcRootType: 'user global',
        hops: ['a', 'b'],
        elements: [
          RetainingElement(kind: RetainingElementKind.instance, className: 'Leaky'),
          RetainingElement(kind: RetainingElementKind.staticField, field: 'cache', ownerIsLibrary: true),
        ],
      );

      expect(_read(TraceBuilder.structure(path)!), ['library .cache', 'Leaky']);
    });

    test('a list slot and a map key that are not known are marked unknown', () {
      const path = RetainingPathInfo(
        gcRootType: 'user global',
        hops: ['a', 'b', 'c'],
        elements: [
          RetainingElement(kind: RetainingElementKind.instance, className: 'Leaky'),
          RetainingElement(kind: RetainingElementKind.map, className: '_Map'),
          RetainingElement(kind: RetainingElementKind.list, className: '_List'),
        ],
      );

      expect(_read(TraceBuilder.structure(path)!), ['_List [?]', '_Map [?]', 'Leaky']);
    });
  });
}
