import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/retaining_element.dart';
import 'package:leak_sentry/utils/retaining_path_util.dart';
import 'package:vm_service/vm_service.dart';

import 'helpers/vm_fixtures.dart';

RetainingPathInfo _describe(String shape) => RetainingPathUtil.describe(VmFixture.load(shape).path);

List<RetainingElementKind> _kinds(RetainingPathInfo info) => [for (final element in info.elements) element.kind];

void main() {
  group('a path from the VM, as plain data', () {
    test('a leaked object in a top-level list: the object, the list slot, the variable', () {
      final info = _describe('static_top_level_list');
      final [leaked, list, variable] = info.elements;

      expect(info.gcRootType, 'user global');
      expect(_kinds(info), [RetainingElementKind.instance, RetainingElementKind.list, RetainingElementKind.staticField]);
      expect(leaked.className, 'Leaky');
      expect(list.className, '_GrowableList');
      expect(list.index, 0);
      expect(list.length, 5);
      expect(variable.field, 'topList');
      expect(variable.ownerIsLibrary, isTrue);
      expect(variable.className, isNull);
      expect(variable.libraryUri, endsWith('record_vm_fixtures.dart'));
    });

    test('a static member of a class is owned by the class, not the library', () {
      final variable = _describe('static_class_field').elements.last;

      expect(variable.kind, RetainingElementKind.staticField);
      expect(variable.className, 'Holder');
      expect(variable.field, 'field');
      expect(variable.ownerIsLibrary, isFalse);
      expect(variable.libraryUri, endsWith('record_vm_fixtures.dart'));
    });

    test('each object says the field that holds the previous one', () {
      final info = _describe('instance_field_chain');

      expect([for (final element in info.elements) element.field], [null, 'next', 'next', 'topLinks']);
      expect([for (final element in info.elements) element.className], ['Leaky', 'Link', 'Link', null]);
    });

    test('a map holds the previous element under a key, shown as text', () {
      final map = _describe('map_value').elements[1];

      expect(map.kind, RetainingElementKind.map);
      expect(map.className, '_Map');
      expect(map.mapKey, 'k');
      expect(map.mapKeyIsText, isTrue);
      expect(map.length, 2);
    });

    test('a key that has no text of its own is shown by its class', () {
      final key = _describe('map_key').elements[1];

      expect(key.mapKey, 'Leaky');
      expect(key.mapKeyIsText, isFalse);
    });

    test('the context a closure captured is a slot, and the closure holds the context', () {
      final info = _describe('closure_capture');
      final [_, context, closure, _] = info.elements;

      expect(_kinds(info), [
        RetainingElementKind.instance,
        RetainingElementKind.context,
        RetainingElementKind.closure,
        RetainingElementKind.staticField,
      ]);
      expect(context.index, 0);
      expect(context.length, 1);
      expect(closure.field, '_context');
    });

    test('a closure says which function it is, and where it is written', () {
      final closure = _describe('closure_capture').elements[2];

      expect(closure.function, 'buildClosure.<anonymous closure>');
      expect(closure.declaredAt?.uri, endsWith('record_vm_fixtures.dart'));
      expect(closure.declaredAt?.line, isPositive);
      expect(closure.declaredAt?.column, isPositive);
      expect(closure.libraryUri, endsWith('record_vm_fixtures.dart'));
    });

    test('a torn-off method is named by its class and holds its receiver', () {
      final closure = _describe('state_listener_tearoff').elements[1];

      expect(closure.kind, RetainingElementKind.closure);
      expect(closure.function, '_ListenerPageState._onChange');
      expect(closure.receiverClassName, '_ListenerPageState');
      expect(closure.field, '_context');
    });

    test('private names lose the library id the VM appends', () {
      final listener = _describe('state_listener_tearoff').elements[3];

      expect(listener.className, 'ChangeNotifier');
      expect(listener.field, '_listeners');
    });

    test('a timer is held by the static timer heap of the runtime', () {
      final info = _describe('state_timer_closure');
      final timer = info.elements.firstWhere((element) => element.className == '_Timer');
      final heap = info.elements.last;

      expect(timer.field, '_callback');
      expect(heap.kind, RetainingElementKind.staticField);
      expect(heap.className, '_Timer');
      expect(heap.field, '_heap');
      expect(heap.libraryUri, 'dart:isolate');
    });

    test('the leaked object knows its identity hash, and where its class is declared', () {
      final fixture = VmFixture.load('state_static_registry');
      final leaked = RetainingPathUtil.describe(fixture.path).elements.first;

      expect(leaked.identityHash, fixture.identityHash);
      expect(leaked.className, '_RegistryPageState');
      expect(leaked.declaredAt?.member, '_RegistryPageState');
      expect(leaked.declaredAt?.uri, endsWith('record_vm_fixtures.dart'));
      expect(leaked.declaredAt?.line, isPositive);
    });

    test('a static variable says where it is declared', () {
      final variable = _describe('static_class_field').elements.last;

      expect(variable.declaredAt?.uri, endsWith('record_vm_fixtures.dart'));
      expect(variable.declaredAt?.line, isPositive);
    });

    for (final shape in VmFixture.shapes) {
      test('$shape: the hops of text and the elements describe the same steps', () {
        final info = _describe(shape);

        expect(info.elements, hasLength(info.hops.length));
        expect(info.hops, isNotEmpty);
        expect(info.hiddenSteps, 0);
      });
    }
  });

  group('the slot of a list', () {
    RetainingPathInfo describeList({Object? parentField, int? parentListIndex}) => RetainingPathUtil.describe(
      RetainingPath(
        length: 1,
        gcRootType: 'user global',
        elements: [
          RetainingObject(
            value: InstanceRef(id: 'objects/1', kind: InstanceKind.kList, classRef: ClassRef(id: 'classes/1', name: '_GrowableList')),
            parentField: parentField,
            parentListIndex: parentListIndex,
          ),
        ],
      ),
    );

    test('is the list index when the VM sends it, as older VMs do', () {
      expect(describeList(parentListIndex: 3).elements.single.index, 3);
    });

    test('is the parent field when that is all the VM sends, as newer VMs may', () {
      expect(describeList(parentField: 2).elements.single.index, 2);
    });

    test('is the list index when the VM sends both and they differ, because the index is the one that says so', () {
      expect(describeList(parentField: 9, parentListIndex: 4).elements.single.index, 4);
    });

    test('a named field is not a slot', () {
      final element = describeList(parentField: 'next').elements.single;

      expect(element.index, isNull);
      expect(element.field, 'next');
    });
  });

  group('a path the VM cut short', () {
    RetainingObject listElement() => RetainingObject(
      value: InstanceRef(id: 'objects/1', kind: InstanceKind.kList, classRef: ClassRef(id: 'classes/1', name: '_GrowableList')),
      parentField: 0,
      parentListIndex: 0,
    );

    test('says how many steps it left out', () {
      final path = RetainingPath(length: 152, gcRootType: 'user global', elements: [for (var i = 0; i < 100; i++) listElement()]);

      final info = RetainingPathUtil.describe(path);

      expect(info.elements, hasLength(100));
      expect(info.totalLength, 152);
      expect(info.hiddenSteps, 52);
    });

    test('a whole path leaves nothing out', () {
      final path = RetainingPath(length: 3, gcRootType: 'user global', elements: [for (var i = 0; i < 3; i++) listElement()]);

      expect(RetainingPathUtil.describe(path).hiddenSteps, 0);
    });
  });

  group('what the VM can hold something with', () {
    test('a path with no elements has no steps', () {
      final info = RetainingPathUtil.describe(RetainingPath(length: 0, gcRootType: 'class table', elements: []));

      expect(info.elements, isEmpty);
      expect(info.hops, isEmpty);
      expect(info.gcRootType, 'class table');
    });

    test('a field that is not static is not a variable, and a class or function is something else', () {
      final path = RetainingPath(
        length: 3,
        gcRootType: 'user global',
        elements: [
          RetainingObject(value: FieldRef(id: 'fields/1', name: 'x', isStatic: false)),
          RetainingObject(value: ClassRef(id: 'classes/1', name: 'Thing')),
          RetainingObject(value: FuncRef(id: 'functions/1', name: 'run')),
        ],
      );

      expect(_kinds(RetainingPathUtil.describe(path)), [RetainingElementKind.other, RetainingElementKind.other, RetainingElementKind.other]);
    });

    test('an instance the VM names only by kind is still an instance', () {
      final path = RetainingPath(
        length: 1,
        gcRootType: 'stack',
        elements: [RetainingObject(value: InstanceRef(id: 'objects/1', kind: 'PlainInstance'))],
      );

      final element = RetainingPathUtil.describe(path).elements.single;

      expect(element.kind, RetainingElementKind.instance);
      expect(element.className, 'PlainInstance');
    });
  });
}
