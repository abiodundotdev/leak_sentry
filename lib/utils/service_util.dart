import 'dart:developer';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

/// Wraps `dart:developer`'s VM service protocol primitives.
///
/// Every member degrades to nothing (rather than throwing) when the VM service
/// protocol is unavailable, which is always the case on web and is the case in
/// release mode unless explicitly enabled.
class ServiceUtil {
  ServiceUtil._();

  /// The host an Android emulator reaches its development machine's loopback
  /// interface at.
  static const String androidEmulatorHost = '10.0.2.2';

  /// The websocket URIs the app's own VM service might be reached at from
  /// inside the app, best first. Empty where there is no VM service.
  ///
  /// This is asked for afresh each time, because the answer changes: under
  /// `flutter run`, the first answer is the VM service's own address, and about
  /// a tenth of a second later it is the address of the Dart Development
  /// Service that the Flutter tool puts in front of it, which then refuses
  /// direct connections.
  static Future<List<String>> candidateWebSocketUris() async {
    if (kIsWeb) return const [];
    final serviceInfo = await Service.getInfo();
    final uri = serviceInfo.serverWebSocketUri;
    if (uri == null) return const [];
    return candidatesFor(uri, isAndroid: defaultTargetPlatform == TargetPlatform.android);
  }

  /// The addresses to try for a service reported at [uri].
  ///
  /// The address as reported comes first: it is right when the VM service was
  /// not started by the Flutter tool, and it is refused at once when it isn't.
  /// On Android the same port on the emulator's host address comes second,
  /// because with the tool the reported address is the host's loopback, which
  /// an emulator reaches as `10.0.2.2`. A physical device reaches neither, which
  /// is what the connection's cooldown after a failure is for.
  @visibleForTesting
  static List<String> candidatesFor(Uri uri, {required bool isAndroid}) => [
    uri.toString(),
    if (isAndroid && uri.host != androidEmulatorHost) uri.replace(host: androidEmulatorHost).toString(),
  ];

  /// The VM service id of the currently running isolate, or `null` if the VM
  /// service protocol is unavailable.
  static String? get currentIsolateId {
    if (kIsWeb) return null;
    try {
      return Service.getIsolateId(Isolate.current);
    } catch (_) {
      return null;
    }
  }

  /// The VM service object id for [object], or `null` if the VM service
  /// protocol is unavailable.
  ///
  /// The VM keeps every object it hands an id for alive until the id falls out
  /// of a ring of a few thousand, so ask only for objects that are about to be
  /// looked at.
  static String? getObjectId(Object object) {
    if (kIsWeb) return null;
    try {
      return Service.getObjectId(object);
    } catch (_) {
      return null;
    }
  }
}
