/// The VM's id zones, which the lookups of retaining paths take turns using.
///
/// Every object a lookup names gets a temporary id, and the VM keeps an object alive for as long as an id
/// of it lives. A lookup therefore works in a zone of its own and empties it when it is done, so that
/// nothing it looked at is held any longer.
///
/// A zone is emptied and reused, never deleted. In Dart 3.6 to 3.10 (Flutter 3.27 to 3.38) a deleted zone
/// leaves a hole in the VM's list of zones, and the garbage collector walks into it at its next run: the
/// app dies with a segmentation fault. An emptied zone lets go of the same objects and costs 64 KB.
class IdZonePool {
  IdZonePool({
    required Future<String?> Function(String isolateId) create,
    required Future<void> Function(String isolateId, String zoneId) empty,
  }) : _create = create,
       _empty = empty;

  final Future<String?> Function(String isolateId) _create;
  final Future<void> Function(String isolateId, String zoneId) _empty;

  // The zones that are empty and waiting, by the isolate they were made in: a zone belongs to its isolate.
  final Map<String, List<String>> _idle = {};

  /// A zone with no ids in it: one that was given back, else a new one. Null when the VM has none to give.
  /// A zone goes to one lookup at a time. Throws what making a zone throws.
  Future<String?> acquire(String isolateId) async {
    final idle = _idle[isolateId];
    if (idle != null && idle.isNotEmpty) return idle.removeLast();
    return _create(isolateId);
  }

  /// Empties [zoneId], which lets go of every object its ids named, and keeps it for the next lookup.
  ///
  /// A zone that cannot be emptied is not kept, because it may still hold objects and would hand them on to
  /// the next lookup; what emptying it threw is thrown.
  Future<void> release(String isolateId, String zoneId) async {
    await _empty(isolateId, zoneId);
    final idle = _idle[isolateId] ??= [];
    if (!idle.contains(zoneId)) idle.add(zoneId);
  }
}
