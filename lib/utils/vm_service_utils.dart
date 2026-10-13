import 'dart:async';

import 'package:leak_sentry/utils/service_util.dart';
import 'package:leak_sentry/utils/vm_service_connection.dart';
import 'package:meta/meta.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Connects to the running app's own VM service, when one is available.
///
/// Every member returns `null` or `false` on any failure (no VM service,
/// connection error, unsupported platform) instead of throwing, so callers can
/// treat "no VM service" as a normal, expected mode rather than an error.
class VmServiceUtils {
  VmServiceUtils._();

  static final VmServiceConnection _connection = VmServiceConnection(
    candidateUris: ServiceUtil.candidateWebSocketUris,
    connect: vmServiceConnectUri,
  );

  /// The connected [VmService], or `null` if one isn't available.
  ///
  /// The connection is opened once and kept; concurrent callers while it is
  /// being opened share the attempt. After a failed attempt this answers `null`
  /// for a while without trying again.
  static Future<VmService?> getVmService() => _connection.get();

  /// Tells that a call on the connection failed with [error]. If that means the
  /// connection itself is bad, it is dropped so the next call reconnects.
  static void reportFailure(Object error) {
    if (isConnectionFailure(error)) _connection.invalidate();
  }

  /// Whether [error] means the connection is unusable, as opposed to the VM
  /// service answering that it can't do this one thing (a collected object, a
  /// method this VM build doesn't have).
  @visibleForTesting
  static bool isConnectionFailure(Object error) {
    if (error is SentinelException) return false;
    if (error is RPCError) return error.message.contains('disposed');
    return true;
  }

  /// Best-effort request that the VM collect garbage now. Returns whether the
  /// VM confirmed that it did.
  ///
  /// Returns `false` (never throws) if the VM service or isolate id is
  /// unavailable, if the underlying (private, unstable) RPC fails, or if it
  /// doesn't answer within five seconds.
  static Future<bool> forceGC() async {
    final vm = await getVmService();
    if (vm == null) return false;
    final isolateId = ServiceUtil.currentIsolateId;
    if (isolateId == null) return false;
    try {
      await vm.callMethod('_collectAllGarbage', isolateId: isolateId).timeout(const Duration(seconds: 5));
      return true;
    } catch (error) {
      // The RPC is a private VM implementation detail, not guaranteed on every
      // platform/VM build.
      reportFailure(error);
      return false;
    }
  }
}
