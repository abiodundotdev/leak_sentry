import 'package:leak_sentry/models/field_facts.dart';
import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/utils/retaining_path_util.dart';
import 'package:leak_sentry/utils/service_util.dart';
import 'package:leak_sentry/utils/vm_service_utils.dart';

/// The VM-service operations leak detection needs, behind an interface so
/// tests can substitute a deterministic fake for a real VM connection.
abstract class VmBridge {
  /// Forces a full garbage collection. `true` only if the VM confirmed it ran.
  Future<bool> forceGc();

  /// The VM service id of the current isolate, or `null` if unavailable.
  String? get isolateId;

  /// The VM service id of [object], or `null` if unavailable.
  String? objectIdOf(Object object);

  /// Hands out a place for the temporary ids that the VM gives in its answers to
  /// [retainingPath] and [readFields], and returns its id; or null when it cannot (a VM that does
  /// not have them, or no VM service).
  ///
  /// The VM keeps an object alive for as long as it has an id for it, and an id that is not in a
  /// zone of its own lives on in the VM's shared ring until enough newer ones push it out. Every
  /// object on a retaining path gets one, so an analysis that used the shared ring would go on holding
  /// them after it was done.
  Future<String?> openIdZone(String isolateId);

  /// Lets go of every object the ids of the zone [zoneId] held, which makes every id of it stop working,
  /// and keeps the zone for a later [openIdZone]. The zone is emptied, never deleted: see `IdZonePool`.
  /// Never throws.
  Future<void> closeIdZone(String isolateId, String zoneId);

  /// The retaining path of the object with [objectId], or `null` if unavailable. With [idZoneId] the
  /// ids it hands out are in that zone.
  Future<RetainingPathInfo?> retainingPath(String isolateId, String objectId, {String? idZoneId});

  /// What the VM says about the fields of the object with [objectId], or `null`
  /// if it cannot say: the id has expired, or the VM service failed. With [idZoneId] the ids it hands
  /// out are in that zone, and an [objectId] of that zone is understood.
  Future<FieldFacts?> readFields(String isolateId, String objectId, {String? idZoneId});

  /// Whether the VM service can be reached right now.
  Future<bool> isReachable();
}

/// The real VM service, via `dart:developer` and `package:vm_service`.
class RealVmBridge implements VmBridge {
  const RealVmBridge();

  @override
  Future<bool> forceGc() => VmServiceUtils.forceGC();

  @override
  String? get isolateId => ServiceUtil.currentIsolateId;

  @override
  String? objectIdOf(Object object) => ServiceUtil.getObjectId(object);

  @override
  Future<String?> openIdZone(String isolateId) => RetainingPathUtil.openIdZone(isolateId);

  @override
  Future<void> closeIdZone(String isolateId, String zoneId) => RetainingPathUtil.closeIdZone(isolateId, zoneId);

  @override
  Future<RetainingPathInfo?> retainingPath(String isolateId, String objectId, {String? idZoneId}) =>
      RetainingPathUtil.resolveById(isolateId, objectId, idZoneId: idZoneId);

  @override
  Future<FieldFacts?> readFields(String isolateId, String objectId, {String? idZoneId}) =>
      RetainingPathUtil.readFields(isolateId, objectId, idZoneId: idZoneId);

  @override
  Future<bool> isReachable() async => (await VmServiceUtils.getVmService()) != null;
}
