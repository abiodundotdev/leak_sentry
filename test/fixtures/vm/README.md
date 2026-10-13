# Recorded VM service responses

Real `getRetainingPath` / `getObject` answers from a running Flutter app, used as test data for the
retaining-path model and the leak trace builder, so the tests exercise the shapes the VM really sends
instead of shapes imagined from the protocol document.

- Recorded: 2026-10-12, by `leak_entry_app/integration_test/tool/record_vm_fixtures.dart`
  (`flutter test integration_test/tool/record_vm_fixtures.dart -d macos --no-pub`, stdout lines
  `PROBE|shape|kind|json`).
- Environment: Flutter 3.44.2, Dart 3.12.2, VM service protocol 4.21, macOS, debug mode.
- One file per leak shape: `path` is the `getRetainingPath(limit: 100)` answer, `leakedObject` is
  `getObject` of the leaked object (its fields slimmed to name, owner, kind and value), `fieldValues`
  is `getObject` of the lifecycle-ish fields (`_debugLifecycleState`, `_element`, `_ticker`, `_navigator`).
- Pruned, because the parser does not read them and they made the files five times larger: keys that start
  with an underscore (`_vmName`, `_kind`, ...) and `declaredType`, `typeParameters`, `typeClass`,
  `parameterizedClass`.
- The 150-hop chain is not stored: it is rebuilt in code (a list inside a list, 150 times). What was
  recorded for it: `length` is the full length (152) while `elements` stops at the limit (100), cut at the
  root end.
- Script URIs are `file:///...` because the test harness runs from the source tree. An app started with
  `flutter run` reports `package:app/...`.

What the recording settled (the facts the code relies on):

- `elements[0]` is the leaked object and the last element is nearest the root. For everything held by a
  static variable the root type is `user global` and the last element is the static `@Field` (owner: the
  library for a top-level variable, the class for a static member).
- `parentField` / `parentListIndex` / `parentMapKey` on element *i* name the slot of element *i* that holds
  element *i-1*. A list sets both `parentField` (the index, an int) and `parentListIndex`. A map sets
  `parentMapKey` to the key (which is the previous element itself when the leaked object is the key). A
  closure's `parentField` is `_context@<hash>`. Private field names carry an `@<library hash>` suffix.
- A closure's `@Instance` carries `closureFunction` (name, owner chain, `location` with line and column),
  `closureContext` and `closureReceiver`. A tear-off holds its receiver directly in `_context`; a closure
  that captures variables goes through a `@Context` whose slots are unnamed.
- Class, field and function refs carry `location` with `line` and `column`.
- `elements[0].value.identityHashCode` equals `identityHashCode(object)`.
- `getObject` of an instance lists inherited private fields too, with the declaring class in `decl.owner`
  (`State._element`, `State._debugLifecycleState`, `Route._navigator`, `AnimationController._ticker`).
- `RetainingPath.length` is the full length; `elements` is cut at the root end by the limit.
- `createIdZone` works when it is given the names `vm_service` has for them, `IdZoneBackingBufferKind.kRing` (`'Ring'`) and `IdAssignmentPolicy.kAlwaysAllocate` (`'AlwaysAllocate'`); the lowercase `'ring'` of the service documentation's table is rejected. The ids of a path and of the fields read from it are held by the VM until their zone is emptied (`invalidateIdZone`), or, in the shared ring, until enough newer ids push them out: a lookup that used the shared ring went on holding the objects of its path. A zone must never be deleted (`deleteIdZone`): the Dart VM of 3.6 to 3.10 (Flutter 3.27 to 3.38) dies at its next garbage collection, because the collector walks into the hole a deleted zone leaves in the VM's list of zones (the null check came with Dart 3.11). `integration_test/tool/probe_id_zone.dart` in the demo app shows that emptying a zone lets go of the objects and that the zone can be used again.
