import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';

import 'helpers/vm_fixtures.dart';

/// The recorded VM service answers (see `test/fixtures/vm/README.md`) say what
/// the VM really sends. These tests pin the facts the retaining-path model and
/// the leak trace are built on, so a change in what we assume shows up here
/// first, and a re-recording with a newer VM shows what moved.
void main() {
  group('every recorded shape', () {
    for (final shape in VmFixture.shapes) {
      test('$shape starts at the leaked object, which is identified by its identity hash', () {
        final fixture = VmFixture.load(shape);
        final first = fixture.path.elements!.first.value as InstanceRef;

        expect(first.identityHashCode, fixture.identityHash);
        expect(first.classRef!.name, fixture.leakedType.split('<').first);
        expect(fixture.path.length, fixture.path.elements!.length, reason: 'no recorded shape is truncated');
      });
    }
  });

  group('what holds a leaked object', () {
    test('a variable ends the path: a static field, with the root type "user global"', () {
      for (final shape in const ['static_top_level_list', 'static_class_field', 'instance_field_chain', 'map_value', 'closure_capture']) {
        final path = VmFixture.load(shape).path;
        final last = path.elements!.last.value;

        expect(path.gcRootType, 'user global', reason: shape);
        expect(last, isA<FieldRef>(), reason: shape);
        expect((last as FieldRef).isStatic, isTrue, reason: shape);
      }
    });

    test('a top-level variable is owned by its library, a static member by its class', () {
      final topLevel = VmFixture.load('static_top_level_list').path.elements!.last.value as FieldRef;
      final member = VmFixture.load('static_class_field').path.elements!.last.value as FieldRef;

      expect(topLevel.name, 'topList');
      expect(topLevel.owner, isA<LibraryRef>());
      expect((topLevel.owner as LibraryRef).uri, endsWith('record_vm_fixtures.dart'));
      expect(member.name, 'field');
      expect(member.owner, isA<ClassRef>());
      expect((member.owner as ClassRef).name, 'Holder');
    });

    test('a field of an object names the field that holds the previous element', () {
      final elements = VmFixture.load('instance_field_chain').path.elements!;

      // The leaked object holds nothing, each Link holds the one before it in `next`, and the static field is the root.
      expect([for (final element in elements) element.parentField], [null, 'next', 'next', null]);
    });

    test('a list holds the previous element at an index, which is both the parent field and the list index', () {
      final list = VmFixture.load('static_top_level_list').path.elements![1];

      expect((list.value as InstanceRef).kind, InstanceKind.kList);
      expect(list.parentField, 0);
      expect(list.parentListIndex, 0);
    });

    test('a map holds the previous element under a key', () {
      final map = VmFixture.load('map_value').path.elements![1];

      expect((map.value as InstanceRef).kind, InstanceKind.kMap);
      expect(map.parentMapKey, isA<InstanceRef>());
      expect((map.parentMapKey as InstanceRef).valueAsString, 'k');
    });

    test('when the leaked object is the key, the key is the previous element itself', () {
      final fixture = VmFixture.load('map_key');
      final key = fixture.path.elements![1].parentMapKey as InstanceRef;

      expect(key.identityHashCode, fixture.identityHash);
    });
  });

  group('closures', () {
    test('a closure that captures a variable holds a context, and the context slot holds the variable', () {
      final elements = VmFixture.load('closure_capture').path.elements!;
      final context = elements[1];
      final closure = elements[2].value as InstanceRef;

      expect(context.value, isA<ContextRef>());
      expect(context.parentListIndex, 0);
      expect(closure.kind, InstanceKind.kClosure);
      expect(elements[2].parentField, startsWith('_context@'));
    });

    test('the closure says which function it is and where it is written', () {
      final closure = VmFixture.load('closure_capture').path.elements![2].value as InstanceRef;

      expect(closure.closureFunction!.name, '<anonymous closure>');
      expect(closure.closureFunction!.owner, isA<FuncRef>());
      expect((closure.closureFunction!.owner as FuncRef).name, 'buildClosure');
      expect(closure.closureFunction!.location!.line, isPositive);
      expect(closure.closureFunction!.location!.column, isPositive);
      expect(closure.closureFunction!.location!.script!.uri, endsWith('record_vm_fixtures.dart'));
    });

    test('a torn-off method holds its receiver directly, and says so', () {
      final elements = VmFixture.load('state_listener_tearoff').path.elements!;
      final closure = elements[1].value as InstanceRef;

      expect(elements[1].parentField, startsWith('_context@'));
      expect(closure.closureFunction!.name, '_onChange');
      expect((closure.closureReceiver as InstanceRef).identityHashCode, (elements[0].value as InstanceRef).identityHashCode);
    });

    test('a periodic timer holds the callback, which the runtime keeps in a static timer heap', () {
      final elements = VmFixture.load('state_timer_closure').path.elements!;
      final timer = elements.firstWhere((element) {
        final value = element.value;
        return value is InstanceRef && value.classRef?.name == '_Timer';
      });
      final root = elements.last.value as FieldRef;

      expect(timer.parentField, startsWith('_callback@'));
      expect(root.name, startsWith('_heap'));
      expect((root.owner as ClassRef).name, '_Timer');
      expect((root.owner as ClassRef).library!.uri, 'dart:isolate');
    });
  });

  group('where a class is declared', () {
    test('the class of the leaked object carries its file and line', () {
      final leaked = VmFixture.load('static_class_field').path.elements!.first.value as InstanceRef;
      final location = leaked.classRef!.location!;

      expect(leaked.classRef!.name, 'Leaky');
      expect(location.script!.uri, endsWith('record_vm_fixtures.dart'));
      expect(location.line, isPositive);
      expect(location.column, isPositive);
    });
  });

  group('what an object says about itself', () {
    test('getObject lists the fields inherited from a base class, with the class that declares each', () {
      final state = VmFixture.load('state_timer_closure').leakedObject;
      final declaredBy = {for (final field in state.fields!) field.decl!.name!: (field.decl!.owner as ClassRef).name};

      expect(declaredBy['_element'], 'State');
      expect(declaredBy['_debugLifecycleState'], 'State');
      expect(declaredBy['ticks'], '_TimerPageState');
    });

    test('a disposed State has no element, and its lifecycle is defunct', () {
      final fixture = VmFixture.load('state_timer_closure');
      final element = fixture.field('_element');
      final lifecycle = fixture.fieldValue('_debugLifecycleState');

      expect(element.valueAsString, 'null');
      expect(lifecycle.fields!.map((field) => (field.decl!.name, (field.value as InstanceRef).valueAsString)), contains(('_name', 'defunct')));
    });

    test('a disposed AnimationController has no ticker, a disposed Route no navigator', () {
      expect(VmFixture.load('animation_controller').field('_ticker').valueAsString, 'null');
      expect(VmFixture.load('route_static').field('_navigator').valueAsString, 'null');
    });
  });
}
