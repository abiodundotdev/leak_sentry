import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/utils/service_util.dart';
import 'package:leak_sentry/utils/vm_service_connection.dart';
import 'package:leak_sentry/utils/vm_service_utils.dart';
import 'package:vm_service/vm_service.dart';

import 'fakes/fake_time.dart';
import 'helpers/capture_log.dart';
import 'helpers/fake_vm_service.dart';

void main() {
  late FakeTime time;
  late List<String> attempts;

  /// What opens at each reachable address: a new fake VM service every time,
  /// as a new connection is a new one.
  late Map<String, FakeVmService Function()> reachable;

  /// Every fake VM service that was opened, in order.
  late List<FakeVmService> opened;
  late List<String> candidates;
  late int candidateLookups;

  VmServiceConnection connection({
    Duration connectTimeout = const Duration(milliseconds: 50),
    Duration retryAfterFailure = const Duration(seconds: 15),
    Future<VmService> Function(String uri)? connect,
  }) => VmServiceConnection(
    candidateUris: () async {
      candidateLookups++;
      return candidates;
    },
    connect:
        connect ??
        (uri) async {
          attempts.add(uri);
          final open = reachable[uri];
          if (open == null) throw StateError('connection refused: $uri');
          final server = open();
          opened.add(server);
          return server.service;
        },
    clock: time.clock,
    connectTimeout: connectTimeout,
    retryAfterFailure: retryAfterFailure,
  );

  setUp(() {
    time = FakeTime();
    attempts = [];
    reachable = {};
    opened = [];
    candidates = [];
    candidateLookups = 0;
    captureLog();
  });

  test('connects, checks the connection with a call, and keeps it', () async {
    reachable['ws://a'] = FakeVmService.new;
    candidates = ['ws://a'];
    final vm = connection();

    final first = await vm.get();
    final second = await vm.get();

    expect(first, same(opened.single.service));
    expect(second, same(first));
    expect(attempts, ['ws://a'], reason: 'the connection is reused');
    expect(opened.single.requests, ['getVersion'], reason: 'it was talked to before it was trusted');
  });

  test('goes on to the next address when one cannot be reached', () async {
    reachable['ws://second'] = FakeVmService.new;
    candidates = ['ws://first', 'ws://second'];

    final service = await connection().get();

    expect(attempts, ['ws://first', 'ws://second']);
    expect(service, same(opened.single.service));
  });

  test('does not trust a connection that opens and then says nothing, and closes it', () async {
    reachable['ws://silent'] = () => FakeVmService(answersVersion: false);
    reachable['ws://working'] = FakeVmService.new;
    candidates = ['ws://silent', 'ws://working'];

    final service = await connection().get();

    final silent = opened[0];
    final working = opened[1];
    expect(service, same(working.service));
    expect(silent.disposed, isTrue);
  });

  test('has nothing when there are no addresses, or looking for them fails', () async {
    expect(await connection().get(), isNull);

    final failing = VmServiceConnection(
      candidateUris: () => throw StateError('no service'),
      connect: (uri) async => throw StateError('unreachable'),
      clock: time.clock,
    );
    expect(await failing.get(), isNull);
  });

  test('closes a connection that was still opening when it timed out, if it arrives later', () async {
    final late = FakeVmService();
    final arrival = Completer<VmService>();
    candidates = ['ws://slow'];
    final vm = connection(connect: (uri) => arrival.future);

    final service = await vm.get();
    expect(service, isNull);
    arrival.complete(late.service);
    await pumpEventQueue();

    expect(late.disposed, isTrue);
  });

  group('after no address worked', () {
    test('it does not try again for a while, so a GC that cannot use the VM service does not wait every time', () async {
      candidates = ['ws://nothing'];
      final vm = connection();
      expect(await vm.get(), isNull);
      expect(attempts, ['ws://nothing']);

      time.advance(const Duration(seconds: 14));
      expect(await vm.get(), isNull);
      expect(attempts, ['ws://nothing'], reason: 'still cooling down');
      expect(candidateLookups, 1);
    });

    test('it tries again once the wait is over', () async {
      candidates = ['ws://later'];
      final vm = connection();
      expect(await vm.get(), isNull);

      reachable['ws://later'] = FakeVmService.new;
      time.advance(const Duration(seconds: 15));

      expect(await vm.get(), isNotNull);
    });

    test('a success clears the wait', () async {
      reachable['ws://a'] = FakeVmService.new;
      candidates = ['ws://a'];
      final vm = connection();

      expect(await vm.get(), isNotNull);
      vm.invalidate();
      final open = reachable.remove('ws://a')!;
      expect(await vm.get(), isNull, reason: 'the address stopped working');
      reachable['ws://a'] = open;
      time.advance(const Duration(seconds: 15));
      expect(await vm.get(), isNotNull);
    });
  });

  group('invalidating', () {
    test('drops the connection and closes it, and the next call opens a new one at the current address', () async {
      reachable['ws://old'] = FakeVmService.new;
      reachable['ws://new'] = FakeVmService.new;
      candidates = ['ws://old'];
      final vm = connection();
      final first = (await vm.get())!;

      // The VM service moved: under `flutter run` it is reached somewhere else
      // a moment after startup.
      candidates = ['ws://new'];
      vm.invalidate();
      await pumpEventQueue();
      final service = await vm.get();

      expect(opened[0].disposed, isTrue);
      expect(first, same(opened[0].service));
      expect(service, same(opened[1].service));
      expect(attempts, ['ws://old', 'ws://new']);
      expect(candidateLookups, 2, reason: 'the addresses are looked up afresh, never cached');
    });

    test('is not held back by the wait that follows a failure', () async {
      reachable['ws://a'] = FakeVmService.new;
      candidates = ['ws://a'];
      final vm = connection();
      await vm.get();

      vm.invalidate();

      expect(await vm.get(), isNotNull);
      expect(attempts, ['ws://a', 'ws://a']);
    });

    test('does nothing when there is no connection', () {
      expect(connection().invalidate, returnsNormally);
    });
  });

  test('callers that ask while the connection is being opened share the attempt', () async {
    reachable['ws://a'] = FakeVmService.new;
    candidates = ['ws://a'];
    final vm = connection();

    final results = await Future.wait([vm.get(), vm.get(), vm.get()]);

    expect(attempts, ['ws://a']);
    expect(results.toSet(), hasLength(1));
  });

  group('telling a bad connection from a call the VM refused', () {
    test('a collected object or a missing method is not a connection problem', () {
      final sentinel = SentinelException.parse('getRetainingPath', {
        'type': 'Sentinel',
        'kind': 'Collected',
        'valueAsString': '<collected>',
      });

      expect(VmServiceUtils.isConnectionFailure(sentinel), isFalse);
      expect(VmServiceUtils.isConnectionFailure(RPCError('_collectAllGarbage', -32601, 'Method not found')), isFalse);
    });

    test('a disposed connection, a timeout and a broken socket are', () {
      expect(VmServiceUtils.isConnectionFailure(RPCError('getVersion', -32000, 'Service connection disposed')), isTrue);
      expect(VmServiceUtils.isConnectionFailure(TimeoutException('no answer')), isTrue);
      expect(VmServiceUtils.isConnectionFailure(StateError('closed')), isTrue);
    });
  });

  group('the addresses to try', () {
    final reported = Uri.parse('ws://127.0.0.1:45678/AbCdEf=/ws');

    test('the reported address alone, except on Android', () {
      expect(ServiceUtil.candidatesFor(reported, isAndroid: false), ['ws://127.0.0.1:45678/AbCdEf=/ws']);
    });

    test('on Android, the same port on the emulator\'s host address comes second', () {
      expect(ServiceUtil.candidatesFor(reported, isAndroid: true), [
        'ws://127.0.0.1:45678/AbCdEf=/ws',
        'ws://10.0.2.2:45678/AbCdEf=/ws',
      ]);
    });

    test('an address that already is the emulator\'s host is not repeated', () {
      final host = Uri.parse('ws://10.0.2.2:50500/token=/ws');

      expect(ServiceUtil.candidatesFor(host, isAndroid: true), ['ws://10.0.2.2:50500/token=/ws']);
    });
  });
}
