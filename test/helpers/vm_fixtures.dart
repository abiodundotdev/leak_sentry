import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';

/// What the VM service really answered for one leak shape, recorded from a
/// running app (see `test/fixtures/vm/README.md`).
class VmFixture {
  VmFixture._(this._json);

  /// Every recorded shape.
  static const List<String> shapes = [
    'static_top_level_list',
    'static_class_field',
    'instance_field_chain',
    'map_value',
    'map_key',
    'closure_capture',
    'state_timer_closure',
    'state_listener_tearoff',
    'state_static_registry',
    'state_without_initstate',
    'animation_controller',
    'route_static',
  ];

  /// Reads the fixture of [shape]. Tests run from the package root.
  static VmFixture load(String shape) {
    final text = File('test/fixtures/vm/$shape.json').readAsStringSync();
    return VmFixture._(jsonDecode(text) as Map<String, dynamic>);
  }

  final Map<String, dynamic> _json;

  String get shape => _json['shape'] as String;

  /// The runtime type of the leaked object.
  String get leakedType => _json['leakedType'] as String;

  /// `identityHashCode` of the leaked object when it was recorded.
  int get identityHash => _json['identityHash'] as int;

  /// The `getRetainingPath` answer as the VM sent it.
  Map<String, dynamic> get pathJson => _json['path'] as Map<String, dynamic>;

  RetainingPath get path => RetainingPath.parse(pathJson)!;

  /// `getObject` of the leaked object, with its fields slimmed down.
  Instance get leakedObject => Instance.parse(_json['leakedObject'] as Map<String, dynamic>)!;

  /// The value of the field [name] of the leaked object.
  InstanceRef field(String name) =>
      leakedObject.fields!.firstWhere((field) => field.decl!.name == name).value as InstanceRef;

  /// `getObject` of the value of the field [name], for the fields that were read through (an enum, say).
  Instance fieldValue(String name) =>
      Instance.parse((_json['fieldValues'] as Map<String, dynamic>)[name] as Map<String, dynamic>)!;
}
