import 'dart:async';
import 'dart:convert';

import 'package:vm_service/vm_service.dart';

/// A VM service that lives in memory: a real [VmService] client talking to a
/// fake server that answers the few calls LeakSentry makes.
class FakeVmService {
  FakeVmService({this.answersVersion = true}) {
    service = VmService(_toClient.stream, _onRequest, disposeHandler: () async => disposed = true);
  }

  final StreamController<String> _toClient = StreamController<String>();
  late final VmService service;

  /// Whether `getVersion` is answered. When it isn't, the connection looks like
  /// one the VM service is about to cut: it opens, and then says nothing.
  bool answersVersion;

  /// The methods called, in order.
  final List<String> requests = [];

  /// Whether the client was disposed.
  bool disposed = false;

  void _onRequest(String message) {
    final request = jsonDecode(message) as Map<String, dynamic>;
    final method = request['method'] as String;
    final id = request['id'];
    requests.add(method);
    switch (method) {
      case 'getVersion':
        if (answersVersion) _respond(id, {'type': 'Version', 'major': 4, 'minor': 21});
      case '_collectAllGarbage':
        _respond(id, {'type': 'Success'});
    }
  }

  void _respond(Object? id, Map<String, dynamic> result) {
    if (_toClient.isClosed) return;
    _toClient.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }

  /// Ends the connection the way a VM service that cuts a client does.
  Future<void> cut() => _toClient.close();
}
