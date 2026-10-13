import 'package:leak_sentry/models/creation_site.dart';

/// What one element of a retaining path is.
enum RetainingElementKind {
  /// An ordinary object.
  instance,

  /// A list. It holds the previous element at [RetainingElement.index].
  list,

  /// A map. It holds the previous element under [RetainingElement.mapKey].
  map,

  /// A closure, with the function it runs in [RetainingElement.function].
  closure,

  /// The variables a closure captured. They have no names, only slots.
  context,

  /// A static variable, which is what ends a path in most leaks.
  staticField,

  /// Anything else the VM can hold something with.
  other,
}

/// One element of a retaining path, as plain data (no `vm_service` types, so
/// tests need no VM): what holds the object before it, and how.
///
/// The elements of a path come in the VM's order: the first is the leaked
/// object, the last is nearest the GC root. Each element but the first says
/// how it holds the one before it: through a [field], at an [index] (a list
/// slot, or a closure's captured variable), or under a [mapKey].
class RetainingElement {
  const RetainingElement({
    required this.kind,
    this.className,
    this.libraryUri,
    this.identityHash,
    this.declaredAt,
    this.field,
    this.index,
    this.mapKey,
    this.mapKeyIsText = false,
    this.function,
    this.receiverClassName,
    this.ownerIsLibrary = false,
    this.length,
    this.objectId,
  });

  final RetainingElementKind kind;

  /// The class of an object, or the class that declares a static variable. Null
  /// for a top-level variable, which no class declares.
  final String? className;

  /// The library of [className], or the library that declares a top-level
  /// variable, as a URI (`package:app/main.dart`, `dart:core`).
  final String? libraryUri;

  /// `identityHashCode` of the object. The leaked object's matches the hash its
  /// watcher recorded, which is how a path tells another watched object apart.
  final int? identityHash;

  /// Where it is declared: the class of an object, the variable of a static
  /// field, or for a closure the place it is written.
  final CreationSite? declaredAt;

  /// The field of this element that holds the previous one, without the suffix
  /// the VM adds to private names.
  final String? field;

  /// The slot that holds the previous element: a list index, or a captured
  /// variable's position in a context.
  final int? index;

  /// The key the previous element is stored under in this map, as text.
  final String? mapKey;

  /// Whether [mapKey] is a string, which is written in quotes.
  final bool mapKeyIsText;

  /// A closure's function, with what encloses it: `PageState._onTick` for a
  /// torn-off method, `main.<anonymous closure>` for a closure written inside
  /// `main`.
  final String? function;

  /// The class of the object a torn-off method is bound to.
  final String? receiverClassName;

  /// Whether a static variable is a top-level variable (declared by a library)
  /// instead of a static member of a class.
  final bool ownerIsLibrary;

  /// How many entries a list or map has.
  final int? length;

  /// The id the VM gave the object in this answer. It stops working once the
  /// analysis is over, and may then name another object, so anything to be asked
  /// about the object has to be asked during the analysis.
  final String? objectId;

  @override
  String toString() =>
      'RetainingElement($kind${className == null ? '' : ' $className'}'
      '${function == null ? '' : ' $function'}'
      '${field == null ? '' : ', field: $field'}'
      '${index == null ? '' : ', index: $index'}'
      '${mapKey == null ? '' : ', mapKey: $mapKey'})';
}
