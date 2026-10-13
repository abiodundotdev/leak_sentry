import 'dart:async';

import 'package:leak_sentry/core/leak_sentry_log.dart';
import 'package:leak_sentry/object_watcher/uptime_clock.dart';
import 'package:vm_service/vm_service.dart';

/// Opens a connection to the VM service at a websocket address.
typedef VmServiceConnector = Future<VmService> Function(String webSocketUri);

/// One connection to the app's own VM service, kept for as long as it works.
///
/// It copes with what a development setup does to such a connection:
///
/// - Under `flutter run` the VM service is reachable at a different address
///   a moment after startup, and the first connection is cut. A connection is
///   tried on every candidate address and checked with a real call before it
///   is trusted, and it is dropped by [invalidate] when a call on it fails, so
///   the next call reconnects at the address that is current then.
/// - On a device that can reach none of the addresses, every attempt would
///   wait for its timeout. After a failed attempt no new one is made for
///   [retryAfterFailure], so a GC that can't use the VM service doesn't wait
///   every time.
class VmServiceConnection {
  VmServiceConnection({
    required Future<List<String>> Function() candidateUris,
    required VmServiceConnector connect,
    UptimeClock? clock,
    this.connectTimeout = const Duration(seconds: 2),
    this.retryAfterFailure = const Duration(seconds: 15),
  }) : _candidateUris = candidateUris,
       _connect = connect,
       _clock = clock ?? systemUptime;

  final Future<List<String>> Function() _candidateUris;
  final VmServiceConnector _connect;
  final UptimeClock _clock;

  /// How long to wait for one address to connect and answer.
  final Duration connectTimeout;

  /// How long to leave the VM service alone after no address worked.
  final Duration retryAfterFailure;

  VmService? _service;
  Future<VmService?>? _connecting;
  Duration? _failedAt;

  /// The connection, opening it if needed. Null when the VM service can't be
  /// reached, which includes the time right after an attempt failed.
  Future<VmService?> get() {
    final current = _service;
    if (current != null) return Future<VmService?>.value(current);
    final failedAt = _failedAt;
    if (failedAt != null && _clock() - failedAt < retryAfterFailure) return Future<VmService?>.value();
    return _connecting ??= _open().whenComplete(() => _connecting = null);
  }

  /// Drops the connection, because a call on it failed. The next [get] opens a
  /// new one.
  void invalidate() {
    final service = _service;
    _service = null;
    _close(service);
  }

  Future<VmService?> _open() async {
    List<String> uris;
    try {
      uris = await _candidateUris();
    } catch (_) {
      uris = const [];
    }
    for (final uri in uris) {
      final connecting = _connect(uri);
      VmService? service;
      try {
        service = await connecting.timeout(connectTimeout);
        // A connection can succeed on a socket that is about to be cut, so
        // talk to the service before trusting it.
        await service.getVersion().timeout(connectTimeout);
        _service = service;
        _failedAt = null;
        return service;
      } catch (error) {
        LeakSentryLog.d(() => 'Could not use the VM service at $uri: $error');
        _close(service);
        // A connection that was still opening when it timed out may arrive later.
        unawaited(connecting.then<void>(_close, onError: (Object _) {}));
      }
    }
    _failedAt = _clock();
    return null;
  }

  void _close(VmService? service) {
    if (service == null) return;
    unawaited(service.dispose().catchError((Object _) {}));
  }
}
