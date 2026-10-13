import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/models/field_facts.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/retaining_element.dart';
import 'package:leak_sentry/utils/id_zone_pool.dart';
import 'package:leak_sentry/utils/vm_service_utils.dart';
import 'package:meta/meta.dart';
import 'package:vm_service/vm_service.dart';

/// Resolves a human-readable retaining path — the chain of references
/// holding an object alive, from the object back to a GC root — using
/// `vm_service`'s `getRetainingPath` RPC.
///
/// This is diagnostic enrichment only: it requires an active VM service
/// session (debug/profile mode, not web, not release), and returns `null`
/// on any failure rather than throwing. Leak *detection* never depends on
/// this succeeding.
///
/// Deliberately takes only [isolateId]/[objectId] (plain strings), never
/// the leaked object itself: if the caller's own async call chain were
/// still holding a live reference to the object while awaiting this RPC,
/// `getRetainingPath` would trivially find and report "retained by that
/// caller's own suspended stack frame" instead of a meaningful
/// application-level chain. Callers must capture the object's id
/// synchronously (via `dart:developer`'s `Service.getObjectId`) and let go
/// of the object itself before calling this.
class RetainingPathUtil {
  RetainingPathUtil._();

  static const int _maxHops = 100;

  /// How long a lookup may take. It walks the whole heap inside the VM, which in a big app takes a
  /// few seconds; a VM that has not answered after this is not going to.
  static const Duration _lookupTimeout = Duration(seconds: 30);

  /// How long reading the fields of an object may take: one object, which is quick.
  static const Duration _readTimeout = Duration(seconds: 10);

  /// How many ids a zone holds before the oldest are pushed out: the 100 elements of a path, and
  /// the fields of up to 40 objects of it, with room to spare.
  static const int _idZoneCapacity = 8192;

  /// The zones for the temporary ids of the lookups. They are emptied and reused, never deleted: see
  /// [IdZonePool].
  static final IdZonePool _zones = IdZonePool(create: _createIdZone, empty: _emptyIdZone);

  /// Hands out a zone for the temporary ids of one analysis of one leak, and returns its id; or null when
  /// the VM service cannot (no connection, or a VM that does not have zones). It never throws.
  static Future<String?> openIdZone(String isolateId) async {
    final vm = await VmServiceUtils.getVmService();
    if (vm == null) return null;
    try {
      return await _zones.acquire(isolateId);
    } catch (error) {
      VmServiceUtils.reportFailure(error);
      return null;
    }
  }

  /// Empties the zone, which lets go of everything its ids held, and keeps it for another lookup. It never
  /// throws.
  static Future<void> closeIdZone(String isolateId, String zoneId) async {
    try {
      await _zones.release(isolateId, zoneId);
    } catch (error) {
      VmServiceUtils.reportFailure(error);
    }
  }

  static Future<String?> _createIdZone(String isolateId) async {
    final vm = await VmServiceUtils.getVmService();
    if (vm == null) return null;
    final zone = await vm
        .createIdZone(isolateId, IdZoneBackingBufferKind.kRing, IdAssignmentPolicy.kAlwaysAllocate, capacity: _idZoneCapacity)
        .timeout(_readTimeout);
    return zone.id;
  }

  static Future<void> _emptyIdZone(String isolateId, String zoneId) async {
    final vm = await VmServiceUtils.getVmService();
    if (vm == null) throw StateError('The VM service is not there to empty the zone $zoneId');
    await vm.invalidateIdZone(isolateId, zoneId).timeout(_readTimeout);
  }

  /// Best-effort retaining path for the object identified by [objectId] in
  /// isolate [isolateId]. Returns `null` if unavailable.
  static Future<RetainingPathInfo?> resolveById(String isolateId, String objectId, {String? idZoneId}) async {
    final vm = await VmServiceUtils.getVmService();
    if (vm == null) {
      return null;
    }

    try {
      final path = await vm.getRetainingPath(isolateId, objectId, _maxHops, idZoneId: idZoneId).timeout(_lookupTimeout);
      return describe(path);
    } catch (error) {
      VmServiceUtils.reportFailure(error);
      return null;
    }
  }

  /// What the VM says about the fields of the object with [objectId], or `null` if
  /// it cannot say. Like [resolveById], it never throws.
  static Future<FieldFacts?> readFields(String isolateId, String objectId, {String? idZoneId}) async {
    final vm = await VmServiceUtils.getVmService();
    if (vm == null) return null;
    try {
      final object = await vm.getObject(isolateId, objectId, idZoneId: idZoneId).timeout(_readTimeout);
      return object is Instance ? describeFields(object) : null;
    } catch (error) {
      VmServiceUtils.reportFailure(error);
      return null;
    }
  }

  /// Describes what the VM answered: as hops of text, and as plain data.
  ///
  /// The VM keeps the elements nearest the leaked object when the path is longer
  /// than the limit asked for, and says how long the whole path is.
  static RetainingPathInfo describe(RetainingPath path) {
    final raw = path.elements ?? const <RetainingObject>[];
    return RetainingPathInfo(
      gcRootType: path.gcRootType ?? 'unknown',
      hops: raw.map(describeHop).toList(),
      elements: raw.map(_describeElement).toList(),
      totalLength: path.length,
    );
  }

  static RetainingElement _describeElement(RetainingObject element) {
    final value = element.value;
    final parentField = element.parentField;
    // A list says the index twice: as the parent field and as the list index.
    final index = element.parentListIndex ?? (parentField is int ? parentField : null);
    final field = parentField is String ? _publicName(parentField) : null;
    final mapKey = _describeKey(element.parentMapKey);

    if (value is FieldRef && value.isStatic == true) {
      final owner = value.owner;
      return RetainingElement(
        kind: RetainingElementKind.staticField,
        className: owner is ClassRef ? owner.name : null,
        libraryUri: owner is ClassRef ? owner.library?.uri : (owner is LibraryRef ? owner.uri : null),
        ownerIsLibrary: owner is LibraryRef,
        field: _publicName(value.name ?? '?'),
        declaredAt: _siteOf(value.location),
      );
    }
    if (value is ContextRef) {
      return RetainingElement(kind: RetainingElementKind.context, index: index, length: value.length);
    }
    if (value is InstanceRef) {
      final classRef = value.classRef;
      if (value.kind == InstanceKind.kClosure) {
        final function = value.closureFunction;
        return RetainingElement(
          kind: RetainingElementKind.closure,
          libraryUri: _libraryUriOf(function),
          identityHash: value.identityHashCode,
          function: _functionName(function),
          receiverClassName: value.closureReceiver?.classRef?.name,
          declaredAt: _siteOf(function?.location, member: _functionName(function)),
          field: field,
          index: index,
          objectId: value.id,
        );
      }
      return RetainingElement(
        kind: switch (value.kind) {
          InstanceKind.kList => RetainingElementKind.list,
          InstanceKind.kMap => RetainingElementKind.map,
          _ => RetainingElementKind.instance,
        },
        className: classRef?.name ?? value.kind,
        libraryUri: classRef?.library?.uri,
        identityHash: value.identityHashCode,
        declaredAt: _siteOf(classRef?.location, member: classRef?.name),
        field: field,
        index: index,
        mapKey: mapKey,
        mapKeyIsText: _isTextKey(element.parentMapKey),
        length: value.length,
        objectId: value.id,
      );
    }
    return RetainingElement(kind: RetainingElementKind.other, className: _describeValue(value), field: field, index: index);
  }

  /// What the VM says about the fields of [instance]: who declares them, and what
  /// they hold.
  static FieldFacts describeFields(Instance instance) {
    final classes = <String>{};
    final values = <String, String>{};
    for (final field in instance.fields ?? const <BoundField>[]) {
      final declaration = field.decl;
      final owner = declaration?.owner;
      final ownerName = owner is ClassRef ? owner.name : null;
      final name = declaration?.name;
      if (ownerName == null || name == null) continue;
      classes.add(ownerName);
      final value = field.value;
      values['$ownerName.${_publicName(name)}'] = switch (value) {
        InstanceRef() => value.valueAsString ?? value.classRef?.name ?? value.kind ?? '',
        _ => '',
      };
    }
    return FieldFacts(declaringClasses: classes, values: values);
  }

  /// A private name as the VM prints it carries the id of its library after an
  /// `@` (`_listeners@30329750`), which means nothing to a developer.
  static String _publicName(String name) => name.replaceFirst(RegExp(r'@\d+$'), '');

  static CreationSite? _siteOf(SourceLocation? location, {String? member}) {
    final uri = location?.script?.uri;
    if (uri == null) return null;
    return CreationSite(uri: uri, member: member, line: location?.line, column: location?.column);
  }

  static bool _isTextKey(ObjRef? key) => key is InstanceRef && key.kind == InstanceKind.kString;

  /// A map key as text: a string or number as itself, anything else by its class.
  static String? _describeKey(ObjRef? key) {
    if (key is! InstanceRef) return null;
    return key.valueAsString ?? key.classRef?.name ?? key.kind;
  }

  /// The function a closure runs, with what encloses it. A torn-off method is
  /// `Owner.method`; a closure is `enclosing.<anonymous closure>`.
  static String? _functionName(FuncRef? function) {
    final names = <String>[];
    FuncRef? current = function;
    while (current != null) {
      names.insert(0, current.name ?? '?');
      final owner = current.owner;
      if (owner is ClassRef && owner.name != null) names.insert(0, owner.name!);
      current = owner is FuncRef ? owner : null;
    }
    if (names.isEmpty) return null;
    // A torn-off method's implicit closure has the same name as the method it wraps.
    final distinct = <String>[
      for (var i = 0; i < names.length; i++)
        if (i == 0 || names[i] != names[i - 1]) names[i],
    ];
    return distinct.join('.');
  }

  static String? _libraryUriOf(FuncRef? function) {
    dynamic owner = function?.owner;
    while (owner is FuncRef) {
      owner = owner.owner;
    }
    if (owner is LibraryRef) return owner.uri;
    if (owner is ClassRef) return owner.library?.uri;
    return null;
  }

  /// Names one element of a retaining path, with how it holds the one before.
  ///
  /// A static field is the root of most leaks, so it is named by its owner and
  /// name (`Holder._graveyard (static)`) rather than by what the VM calls its
  /// type.
  @visibleForTesting
  static String describeHop(RetainingObject element) {
    final value = element.value;
    final description = _describeValue(value);

    final parentField = element.parentField;
    if (parentField != null) {
      return '$description.$parentField';
    }
    if (element.parentListIndex != null) {
      return '$description[${element.parentListIndex}]';
    }
    if (element.parentMapKey != null) {
      return '$description{key}';
    }
    return description;
  }

  static String _describeValue(ObjRef? value) {
    if (value is InstanceRef) return value.classRef?.name ?? value.kind ?? 'Object';
    if (value is FieldRef) {
      final ownerName = _ownerName(value.owner);
      final name = [if (ownerName != null && ownerName.isNotEmpty) ownerName, value.name ?? '?'].join('.');
      return value.isStatic == true ? '$name (static)' : name;
    }
    if (value is ClassRef) return 'class ${value.name}';
    if (value is FuncRef) return 'function ${value.name}';
    return value?.runtimeType.toString() ?? 'Object';
  }

  /// The class that declares a field, or for a top-level one the library: its
  /// name, or the name of its file when it has none.
  static String? _ownerName(ObjRef? owner) {
    if (owner is ClassRef) return owner.name;
    if (owner is LibraryRef) {
      final name = owner.name;
      if (name != null && name.isNotEmpty) return name;
      return owner.uri?.split('/').last;
    }
    return null;
  }
}
