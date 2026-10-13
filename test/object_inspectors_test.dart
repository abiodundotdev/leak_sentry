import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/analysis/leak_trace.dart';
import 'package:leak_sentry/analysis/node_status.dart';
import 'package:leak_sentry/analysis/object_inspectors.dart';
import 'package:leak_sentry/analysis/trace_builder.dart';
import 'package:leak_sentry/models/field_facts.dart';
import 'package:leak_sentry/utils/retaining_path_util.dart';
import 'package:vm_service/vm_service.dart';

import 'helpers/vm_fixtures.dart';

InspectedNode _node({
  TraceNodeKind kind = TraceNodeKind.instance,
  String name = 'Thing',
  String? library = 'package:app/thing.dart',
  FieldFacts? facts,
  bool leaked = false,
  String? leakedReason,
  String? alsoExpectedGone,
}) => InspectedNode(
  node: TraceNode(kind: kind, name: name, library: library),
  isLeakedObject: leaked,
  facts: facts,
  leakedReason: leakedReason,
  alsoExpectedGone: alsoExpectedGone,
);

void main() {
  group('the object that leaked', () {
    const inspector = LeakedObjectInspector();

    test('should be gone, and the reason it was expected to be is told', () {
      final finding = inspector.inspect(_node(leaked: true, leakedReason: 'A State that was disposed.'))!;

      expect(finding.status, NodeStatus.shouldBeGone);
      expect(finding.reason, 'Expected to be gone: A State that was disposed.');
    });

    test('should be gone with no reason given too', () {
      for (final reason in [null, '']) {
        final finding = inspector.inspect(_node(leaked: true, leakedReason: reason))!;

        expect(finding.status, NodeStatus.shouldBeGone);
        expect(finding.reason, 'This is the object that should be gone.');
      }
    });

    test('is the only step it speaks of', () {
      expect(inspector.inspect(_node(leakedReason: 'A State that was disposed.')), isNull);
    });
  });

  group('a static variable', () {
    const inspector = StaticHolderInspector();

    test('lives as long as the app, and so does what holds it', () {
      final finding = inspector.inspect(_node(kind: TraceNodeKind.staticHolder))!;

      expect(finding.status, NodeStatus.inUse);
      expect(finding.reason, 'A static variable lives as long as the app.');
    });

    test('is nothing a list, a map, a closure or an object is', () {
      for (final kind in [TraceNodeKind.instance, TraceNodeKind.list, TraceNodeKind.map, TraceNodeKind.closure]) {
        expect(inspector.inspect(_node(kind: kind)), isNull, reason: '$kind');
      }
    });
  });

  group('what Dart\'s own event loop keeps', () {
    const inspector = RuntimeInternalsInspector();

    test('is in use: it is what keeps every pending timer', () {
      final finding = inspector.inspect(_node(name: '_Timer', library: 'dart:isolate'))!;

      expect(finding.status, NodeStatus.inUse);
    });

    test('is known by the library, not by the name', () {
      expect(inspector.inspect(_node(name: '_Timer', library: 'package:app/timer.dart')), isNull);
      expect(inspector.inspect(_node(name: '_Timer', library: 'dart:core')), isNull);
      expect(inspector.inspect(_node(name: '_Timer', library: null)), isNull);
    });

    test('is an object, not a list, a map or a closure', () {
      expect(inspector.inspect(_node(kind: TraceNodeKind.list, library: 'dart:isolate')), isNull);
      expect(inspector.inspect(_node(kind: TraceNodeKind.closure, library: 'dart:isolate')), isNull);
    });
  });

  group('what an app has one of for as long as it runs', () {
    const inspector = FrameworkSingletonInspector();

    test('is in use, when it is one of the framework\'s', () {
      for (final (name, library) in const [
        ('BuildOwner', 'package:flutter/src/widgets/framework.dart'),
        ('PipelineOwner', 'package:flutter/src/rendering/object.dart'),
        ('FocusManager', 'package:flutter/src/widgets/focus_manager.dart'),
        ('PlatformDispatcher', 'dart:ui'),
        ('WidgetsFlutterBinding', 'package:flutter/src/widgets/binding.dart'),
        ('AutomatedTestWidgetsFlutterBinding', 'package:flutter_test/src/binding.dart'),
        ('IntegrationTestWidgetsFlutterBinding', 'package:integration_test/integration_test.dart'),
      ]) {
        expect(inspector.inspect(_node(name: name, library: library))?.status, NodeStatus.inUse, reason: name);
      }
    });

    test('is not so for an app\'s own class that has the same name', () {
      expect(inspector.inspect(_node(name: 'BuildOwner', library: 'package:app/owner.dart')), isNull);
      expect(inspector.inspect(_node(name: 'MyBinding', library: 'package:app/binding.dart')), isNull);
    });

    test('is not so for an app whose name starts like the framework\'s', () {
      expect(inspector.inspect(_node(name: 'HomeBinding', library: 'package:flutter_application_1/home.dart')), isNull);
      expect(inspector.inspect(_node(name: 'BuildOwner', library: 'package:flutter_riverpod/src/owner.dart')), isNull);
    });

    test('is not so for the rest of the framework', () {
      expect(inspector.inspect(_node(name: 'StatefulElement', library: 'package:flutter/src/widgets/framework.dart')), isNull);
      expect(inspector.inspect(_node(name: 'ChangeNotifier', library: 'package:flutter/src/foundation/change_notifier.dart')), isNull);
    });

    test('is an object, not a static variable that is named like one', () {
      expect(
        inspector.inspect(_node(kind: TraceNodeKind.staticHolder, name: 'BuildOwner', library: 'package:flutter/src/widgets/framework.dart')),
        isNull,
      );
    });
  });

  group('another object that is watched and retained', () {
    const inspector = OtherWatchedObjectInspector();

    test('should be gone, and what holds it too', () {
      final finding = inspector.inspect(_node(alsoExpectedGone: 'A State that was disposed.'))!;

      expect(finding.status, NodeStatus.shouldBeGone);
      expect(finding.reason, 'Also expected to be gone: A State that was disposed.');
    });

    test('is not what the leaked object is: that is told once, by its own inspector', () {
      expect(inspector.inspect(_node(leaked: true, alsoExpectedGone: 'A State that was disposed.')), isNull);
    });

    test('is not said of an object nothing says it of', () {
      expect(inspector.inspect(_node()), isNull);
    });
  });

  group('what the fields of an object say', () {
    FieldFacts facts(String owner, String field, String value) =>
        FieldFacts(declaringClasses: {owner}, values: {'$owner.$field': value});

    // The inspector, the class that declares the field, the field, what it holds
    // when the object is gone, and what when it is alive.
    final cases = <({NodeInspector inspector, String owner, String field, String gone, String alive})>[
      (inspector: const ChangeNotifierInspector(), owner: 'ChangeNotifier', field: '_debugDisposed', gone: 'true', alive: 'false'),
      (inspector: const StateInspector(), owner: 'State', field: '_element', gone: 'null', alive: 'StatefulElement'),
      (inspector: const ElementInspector(), owner: 'Element', field: '_widget', gone: 'null', alive: 'Padding'),
      (inspector: const RouteInspector(), owner: 'Route', field: '_navigator', gone: 'null', alive: 'NavigatorState'),
      (
        inspector: const AnimationControllerInspector(),
        owner: 'AnimationController',
        field: '_ticker',
        gone: 'null',
        alive: 'Ticker',
      ),
      (inspector: const RenderObjectInspector(), owner: 'RenderObject', field: '_debugDisposed', gone: 'true', alive: 'false'),
    ];

    for (final c in cases) {
      group(c.inspector.runtimeType.toString(), () {
        test('says it should be gone when it holds what an object that is gone holds', () {
          final finding = c.inspector.inspect(_node(facts: facts(c.owner, c.field, c.gone)))!;

          expect(finding.status, NodeStatus.shouldBeGone);
          expect(finding.reason, isNotEmpty);
        });

        test('says it is in use when it holds anything else', () {
          final finding = c.inspector.inspect(_node(facts: facts(c.owner, c.field, c.alive)))!;

          expect(finding.status, NodeStatus.inUse);
          expect(finding.reason, isNotEmpty);
        });

        test('has no say when it was not asked about the fields, or the VM could not tell', () {
          expect(c.inspector.inspect(_node()), isNull);
          expect(c.inspector.inspect(_node(facts: const FieldFacts())), isNull);
        });

        test('has no say about an object that does not belong to the class', () {
          expect(c.inspector.inspect(_node(facts: facts('SomethingElse', c.field, c.gone))), isNull);
        });

        test('has no say when the facts say the object belongs to no class, whatever they have for fields', () {
          expect(c.inspector.inspect(_node(facts: FieldFacts(values: {'${c.owner}.${c.field}': c.gone}))), isNull);
        });

        test('has no say when the class has no such field to read', () {
          expect(c.inspector.inspect(_node(facts: FieldFacts(declaringClasses: {c.owner}))), isNull);
          expect(c.inspector.inspect(_node(facts: FieldFacts(declaringClasses: {c.owner}, values: {'${c.owner}.another': c.gone}))), isNull);
        });

        test('does not take the field of another class of the same name for its own', () {
          expect(
            c.inspector.inspect(
              _node(facts: FieldFacts(declaringClasses: {c.owner, 'Mine'}, values: {'Mine.${c.field}': c.gone})),
            ),
            isNull,
          );
        });
      });
    }

    test('the reasons tell the live from the gone', () {
      for (final c in cases) {
        final gone = c.inspector.inspect(_node(facts: facts(c.owner, c.field, c.gone)))!.reason;
        final alive = c.inspector.inspect(_node(facts: facts(c.owner, c.field, c.alive)))!.reason;

        expect(gone, isNot(alive), reason: c.owner);
      }
    });

    test('are kept apart from the ones that need only the path', () {
      final structural = structuralInspectors.map((inspector) => inspector.runtimeType).toSet();
      final fields = fieldInspectors.map((inspector) => inspector.runtimeType).toSet();

      expect(structural.intersection(fields), isEmpty);
      expect(fields, cases.map((c) => c.inspector.runtimeType).toSet(), reason: 'every one of them is tested above');
    });
  });

  group('what the VM says about the fields of an object, as the VM said it', () {
    FieldFacts factsOf(String shape) => RetainingPathUtil.describeFields(VmFixture.load(shape).leakedObject);

    test('a State: its own fields and the framework\'s, and whether it still has an element', () {
      final facts = factsOf('state_static_registry');

      expect(facts.declaringClasses, {'State'});
      expect(facts.valueOf('State', '_element'), 'null');
      expect(facts.valueOf('State', '_widget'), 'RegistryPage', reason: 'an object is told by its class');
      expect(facts.declares('State'), isTrue);
      expect(facts.declares('ChangeNotifier'), isFalse);
    });

    test('a State with fields of its own: they are told by the class that declares them', () {
      final facts = factsOf('state_timer_closure');

      expect(facts.declaringClasses, {'State', '_TimerPageState'});
      expect(facts.valueOf('_TimerPageState', 'ticks'), '2', reason: 'a number is told by its value');
    });

    test('an AnimationController: told apart from what it inherits from, with no ticker once disposed', () {
      final facts = factsOf('animation_controller');

      expect(facts.declares('AnimationController'), isTrue);
      expect(facts.valueOf('AnimationController', '_ticker'), 'null');
      expect(facts.valueOf('AnimationController', 'lowerBound'), '0.0');
      expect(facts.valueOf('AnimationController', 'duration'), 'Duration');
    });

    test('a Route: the fields of every class it inherits from', () {
      final facts = factsOf('route_static');

      expect(facts.declaringClasses, containsAll(['Route', 'TransitionRoute', 'ModalRoute', 'PageRoute', 'MaterialPageRoute']));
      expect(facts.valueOf('Route', '_navigator'), 'null', reason: 'a route its navigator let go of has none');
      expect(facts.valueOf('TransitionRoute', '_popFinalized'), 'true');
      expect(facts.valueOf('ModalRoute', '_offstage'), 'false');
    });

    test('an object of the app: a string is told by what it says', () {
      final facts = factsOf('static_class_field');

      expect(facts.declaringClasses, {'Leaky'});
      expect(facts.valueOf('Leaky', 'tag'), 'static field');
    });

    test('says nothing about what no class declares', () {
      expect(factsOf('static_class_field').valueOf('Leaky', 'nothing'), isNull);
      expect(factsOf('static_class_field').valueOf('Nobody', 'tag'), isNull);
    });

    test('an object with no fields has no facts', () {
      final instance = Instance.parse({
        'type': 'Instance',
        'id': 'objects/1',
        'kind': 'PlainInstance',
        'class': {'type': '@Class', 'id': 'classes/1', 'name': 'Empty'},
      })!;

      final facts = RetainingPathUtil.describeFields(instance);

      expect(facts.declaringClasses, isEmpty);
      expect(facts.values, isEmpty);
    });

    test('a private field is named as the developer wrote it, without the id of its library', () {
      final instance = Instance.parse({
        'type': 'Instance',
        'id': 'objects/1',
        'kind': 'PlainInstance',
        'class': {'type': '@Class', 'id': 'classes/1', 'name': 'Thing'},
        'fields': [
          {
            'decl': {
              'type': '@Field',
              'id': 'fields/1',
              'name': '_secret@12345',
              'owner': {'type': '@Class', 'id': 'classes/1', 'name': 'Thing'},
            },
            'value': {'type': '@Instance', 'kind': 'Int', 'id': 'objects/2', 'valueAsString': '7', 'class': {'type': '@Class', 'id': 'classes/2', 'name': '_Smi'}},
          },
        ],
      })!;

      expect(RetainingPathUtil.describeFields(instance).valueOf('Thing', '_secret'), '7');
    });

    test('a field the VM did not say who declares is left out, and the rest are not', () {
      final instance = Instance.parse({
        'type': 'Instance',
        'id': 'objects/1',
        'kind': 'PlainInstance',
        'class': {'type': '@Class', 'id': 'classes/1', 'name': 'Thing'},
        'fields': [
          {
            'decl': {'type': '@Field', 'id': 'fields/1', 'name': 'orphan'},
            'value': {'type': '@Instance', 'kind': 'Null', 'id': 'objects/2', 'valueAsString': 'null', 'class': {'type': '@Class', 'id': 'classes/2', 'name': 'Null'}},
          },
          {
            'decl': {
              'type': '@Field',
              'id': 'fields/2',
              'name': 'kept',
              'owner': {'type': '@Class', 'id': 'classes/1', 'name': 'Thing'},
            },
            'value': {'type': '@Instance', 'kind': 'Bool', 'id': 'objects/3', 'valueAsString': 'true', 'class': {'type': '@Class', 'id': 'classes/3', 'name': 'bool'}},
          },
        ],
      })!;

      final facts = RetainingPathUtil.describeFields(instance);

      expect(facts.declaringClasses, {'Thing'});
      expect(facts.values, {'Thing.kept': 'true'});
    });
  });

  group('the verdicts of the paths the VM really gave', () {
    LeakTrace traceOf(String shape, {Map<String, FieldFacts> facts = const {}}) {
      final path = RetainingPathUtil.describe(VmFixture.load(shape).path);
      return TraceBuilder.build(path, leakedReason: 'A State that was disposed.', facts: facts)!;
    }

    String statuses(LeakTrace trace) => [
      for (final node in trace.nodes)
        switch (node.status!) {
          NodeStatus.inUse => 'E',
          NodeStatus.shouldBeGone => 'S',
          NodeStatus.unclear => 'U',
        },
    ].join();

    test('what a static variable holds: it is in use, down to the leaked object', () {
      for (final shape in const ['static_top_level_list', 'map_value', 'closure_capture', 'state_static_registry', 'state_without_initstate', 'animation_controller', 'route_static']) {
        expect(statuses(traceOf(shape)), 'EUS', reason: shape);
      }
      expect(statuses(traceOf('static_class_field')), 'ES');
      expect(statuses(traceOf('instance_field_chain')), 'EUUS');
    });

    test('the leaked object says why it was expected to be gone', () {
      expect(traceOf('state_static_registry').nodes.last.note, 'Expected to be gone: A State that was disposed.');
    });

    test('the likely cause is where a static variable holds something that nothing says is in use', () {
      final trace = traceOf('state_static_registry');

      expect(trace.title, 'record_vm_fixtures.dart.topList');
      expect(trace.suspects.map((suspect) => suspect.reference.name), ['.topList', '[1]']);
      expect(trace.fingerprint, endsWith('record_vm_fixtures.dart:topList|dart:core:_GrowableList:[x]'));
    });

    test('a static member is held by its class, and that is the likely cause', () {
      final trace = traceOf('static_class_field');

      expect(trace.title, 'Holder.field');
      expect(trace.suspects, hasLength(1));
    });

    test('a timer: Dart\'s own event loop is in use, and the callback is where the leak starts', () {
      final trace = traceOf('state_timer_closure');

      expect(statuses(trace), 'EEEE${'U' * 5}S');
      expect(trace.title, '_Timer._callback');
      expect(trace.fingerprint, startsWith('dart:isolate:_Timer:_callback|'), reason: 'what is in use above the callback is not a cause');
      expect(trace.fingerprint, isNot(contains('_heap')));
      expect(trace.suspects.first.node.library, 'dart:isolate');
      expect(trace.suspects.map((suspect) => suspect.reference.genericName), ['_callback', for (var i = 0; i < 5; i++) '<captured>']);
    });

    test('a listener: what the VM can say about the notifier moves the likely cause down to it', () {
      final fixture = VmFixture.load('state_listener_tearoff');
      final notifierId = (fixture.pathJson['elements'] as List)[3]['value']['id'] as String;

      final without = traceOf('state_listener_tearoff');
      final alive = traceOf(
        'state_listener_tearoff',
        facts: {
          notifierId: const FieldFacts(declaringClasses: {'ChangeNotifier'}, values: {'ChangeNotifier._debugDisposed': 'false'}),
        },
      );

      expect(statuses(without), 'EUUUS');
      expect(without.title, 'record_vm_fixtures.dart.globalNotifier');
      expect(statuses(alive), 'EEUUS');
      expect(alive.title, 'ChangeNotifier._listeners');
      expect(alive.nodes[1].note, 'A ChangeNotifier that has not been disposed.');
      expect(alive.fingerprint, without.fingerprint, reason: 'what the VM said does not make it another leak');
    });

    test('and a notifier that was disposed is where the leak is, so it holds the cause no longer', () {
      final fixture = VmFixture.load('state_listener_tearoff');
      final notifierId = (fixture.pathJson['elements'] as List)[3]['value']['id'] as String;

      final trace = traceOf(
        'state_listener_tearoff',
        facts: {notifierId: const FieldFacts(declaringClasses: {'ChangeNotifier'}, values: {'ChangeNotifier._debugDisposed': 'true'})},
      );

      expect(statuses(trace), 'ESSSS');
      expect(trace.nodes[1].note, 'A ChangeNotifier that was disposed.');
      expect(trace.suspects.map((suspect) => suspect.node.name), ['record_vm_fixtures.dart']);
    });

    test('the ones to ask the VM about are the objects that may be a notifier, a State or a Route', () {
      final fixture = VmFixture.load('state_listener_tearoff');
      final notifierId = (fixture.pathJson['elements'] as List)[3]['value']['id'] as String;

      expect(TraceBuilder.objectsToInspect(traceOf('state_listener_tearoff')), [notifierId]);
      expect(TraceBuilder.objectsToInspect(traceOf('state_static_registry')), isEmpty, reason: 'a list, and the leaked object');
      expect(TraceBuilder.objectsToInspect(traceOf('state_timer_closure')), isEmpty, reason: 'the timer is Dart\'s, the rest are closures');
    });

    test('leaks held the same way have the same fingerprint, whatever they hold', () {
      final fingerprints = {for (final shape in VmFixture.shapes) shape: traceOf(shape).fingerprint!};
      const sameWay = [
        ['static_top_level_list', 'state_static_registry', 'state_without_initstate', 'animation_controller', 'route_static'],
        ['map_value', 'map_key'],
      ];

      for (final shapes in sameWay) {
        expect({for (final shape in shapes) fingerprints[shape]}, hasLength(1), reason: '$shapes');
      }
      final oneOfEach = [
        for (final shapes in sameWay) shapes.first,
        'static_class_field',
        'instance_field_chain',
        'closure_capture',
        'state_timer_closure',
        'state_listener_tearoff',
      ];
      expect({for (final shape in oneOfEach) fingerprints[shape]}, hasLength(oneOfEach.length), reason: 'each other way is a leak of its own');
    });

    test('no fingerprint holds an address, an identity or a slot', () {
      for (final shape in VmFixture.shapes) {
        final fingerprint = traceOf(shape).fingerprint!;

        expect(RegExp(r'\d{4,}').hasMatch(fingerprint), isFalse, reason: '$shape: $fingerprint');
        expect(RegExp(r'\[\d+\]').hasMatch(fingerprint), isFalse, reason: '$shape: $fingerprint');
      }
    });
  });
}
