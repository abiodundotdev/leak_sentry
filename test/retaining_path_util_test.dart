import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/utils/retaining_path_util.dart';
import 'package:vm_service/vm_service.dart';

// The package's constructors need an id for every reference.
InstanceRef _instance(String className) =>
    InstanceRef(id: 'objects/1', kind: 'PlainInstance', classRef: ClassRef(id: 'classes/1', name: className));

void main() {
  group('naming a hop', () {
    test('an object is named by its class', () {
      expect(RetainingPathUtil.describeHop(RetainingObject(value: _instance('Leaky'))), 'Leaky');
    });

    test('says which field of an object holds the one before it', () {
      final hop = RetainingObject(value: _instance('Holder'), parentField: 'cache');

      expect(RetainingPathUtil.describeHop(hop), 'Holder.cache');
    });

    test('a list holds the one before it at an index, which the VM gives as the parent field', () {
      expect(RetainingPathUtil.describeHop(RetainingObject(value: _instance('_GrowableList'), parentField: 0)), '_GrowableList.0');
      expect(RetainingPathUtil.describeHop(RetainingObject(value: _instance('List'), parentListIndex: 2)), 'List[2]');
    });

    test('a map holds the one before it under a key', () {
      final hop = RetainingObject(value: _instance('_Map'), parentMapKey: _instance('String'));

      expect(RetainingPathUtil.describeHop(hop), '_Map{key}');
    });

    test('an instance with no class falls back to its kind', () {
      expect(RetainingPathUtil.describeHop(RetainingObject(value: InstanceRef(id: 'objects/2', kind: 'Closure'))), 'Closure');
      expect(RetainingPathUtil.describeHop(RetainingObject(value: InstanceRef(id: 'objects/3'))), 'Object');
    });

    test('a static field is named by the class that declares it, and says it is static', () {
      final field = FieldRef(id: 'fields/1', name: '_graveyard', owner: ClassRef(id: 'classes/2', name: 'PageRegistry'), isStatic: true);

      expect(RetainingPathUtil.describeHop(RetainingObject(value: field)), 'PageRegistry._graveyard (static)');
    });

    test('a top-level variable is named by its library, or by its file when the library has no name', () {
      final named = FieldRef(
        id: 'fields/2',
        name: 'instances',
        owner: LibraryRef(id: 'libraries/1', name: 'registry', uri: 'package:app/registry.dart'),
        isStatic: true,
      );
      final unnamed = FieldRef(
        id: 'fields/3',
        name: '_leaks',
        owner: LibraryRef(id: 'libraries/2', name: '', uri: 'package:app/main.dart'),
        isStatic: true,
      );

      expect(RetainingPathUtil.describeHop(RetainingObject(value: named)), 'registry.instances (static)');
      expect(RetainingPathUtil.describeHop(RetainingObject(value: unnamed)), 'main.dart._leaks (static)');
    });

    test('an instance field is named without saying it is static', () {
      final field = FieldRef(id: 'fields/4', name: 'controller', owner: ClassRef(id: 'classes/3', name: 'PageState'), isStatic: false);

      expect(RetainingPathUtil.describeHop(RetainingObject(value: field)), 'PageState.controller');
    });

    test('a field whose owner the VM did not say is just named', () {
      expect(RetainingPathUtil.describeHop(RetainingObject(value: FieldRef(id: 'fields/5', name: 'x', isStatic: true))), 'x (static)');
      expect(RetainingPathUtil.describeHop(RetainingObject(value: FieldRef(id: 'fields/6', isStatic: false))), '?');
    });

    test('a class and a function are named as such', () {
      expect(RetainingPathUtil.describeHop(RetainingObject(value: ClassRef(id: 'classes/4', name: 'Config'))), 'class Config');
      expect(RetainingPathUtil.describeHop(RetainingObject(value: FuncRef(id: 'functions/1', name: 'build'))), 'function build');
    });

    test('anything else is named by what the VM calls it, and a missing value is an Object', () {
      expect(RetainingPathUtil.describeHop(RetainingObject(value: ContextRef(id: 'contexts/1', length: 2))), 'ContextRef');
      expect(RetainingPathUtil.describeHop(RetainingObject()), 'Object');
    });
  });
}
