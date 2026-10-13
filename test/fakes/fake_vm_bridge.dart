import 'package:leak_sentry/models/field_facts.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/vm_bridge.dart';

/// A deterministic [VmBridge] for tests: it counts calls, can be told to
/// fail, and lets a test run code (or block) at the moment of a call.
class FakeVmBridge implements VmBridge {
  bool forceGcSucceeds = true;
  int forceGcCalls = 0;
  int retainingPathCalls = 0;

  /// Awaited inside [forceGc], so a test can hold a GC open.
  Future<void> Function()? onForceGc;

  /// Run synchronously inside [retainingPath].
  void Function()? onRetainingPath;

  /// Awaited inside [retainingPath], so a test can hold a lookup open.
  Future<void> Function()? retainingPathGate;

  /// What [isReachable] says.
  bool reachable = true;

  /// What [readFields] answers, by object id. An id that is not here has expired.
  final Map<String, FieldFacts> fieldFacts = {};

  /// The ids [readFields] was asked about, in order.
  final List<String> fieldReads = [];

  /// Thrown by [readFields], to be a VM service that fails.
  Object? readFieldsError;

  /// Whether this VM has id zones: when it has not, [openIdZone] answers null.
  bool idZonesSupported = true;

  /// Thrown by [openIdZone], to be a VM service that fails.
  Object? openIdZoneError;

  /// Thrown by [closeIdZone].
  Object? closeIdZoneError;

  /// The zones that were opened, in order, and which of them are still open.
  final List<String> zonesOpened = [];
  final Set<String> zonesOpen = {};

  /// What happened to zones and what was asked in them, in order: `open zones/1`, `path zones/1`,
  /// `read zones/1`, `close zones/1`.
  final List<String> zoneEvents = [];

  /// The zone each call was made in, in order: null when it was made in none.
  final List<String?> pathZones = [];
  final List<String?> readZones = [];

  /// What [retainingPath] answers for an object id that is a key here, instead of [path].
  final Map<String, RetainingPathInfo?> pathsById = {};

  RetainingPathInfo? path = const RetainingPathInfo(gcRootType: 'user global', hops: ['Leaked', 'Holder.field']);

  @override
  Future<bool> forceGc() async {
    forceGcCalls++;
    await onForceGc?.call();
    return forceGcSucceeds;
  }

  @override
  Future<bool> isReachable() async => reachable;

  @override
  Future<String?> openIdZone(String isolateId) async {
    final error = openIdZoneError;
    if (error != null) throw error;
    if (!idZonesSupported) return null;
    final zone = 'zones/${zonesOpened.length + 1}';
    zonesOpened.add(zone);
    zonesOpen.add(zone);
    zoneEvents.add('open $zone');
    return zone;
  }

  @override
  Future<void> closeIdZone(String isolateId, String zoneId) async {
    zonesOpen.remove(zoneId);
    zoneEvents.add('close $zoneId');
    final error = closeIdZoneError;
    if (error != null) throw error;
  }

  @override
  Future<FieldFacts?> readFields(String isolateId, String objectId, {String? idZoneId}) async {
    readZones.add(idZoneId);
    zoneEvents.add('read $idZoneId');
    fieldReads.add(objectId);
    final error = readFieldsError;
    if (error != null) throw error;
    return fieldFacts[objectId];
  }

  @override
  String? get isolateId => 'isolates/1';

  @override
  String? objectIdOf(Object object) => 'objects/${identityHashCode(object)}';

  @override
  Future<RetainingPathInfo?> retainingPath(String isolateId, String objectId, {String? idZoneId}) async {
    pathZones.add(idZoneId);
    zoneEvents.add('path $idZoneId');
    retainingPathCalls++;
    onRetainingPath?.call();
    await retainingPathGate?.call();
    return pathsById.containsKey(objectId) ? pathsById[objectId] : path;
  }
}
