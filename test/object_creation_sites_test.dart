import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/models/object_creation_sites.dart';

import 'helpers/force_gc.dart';

class _A {}

void main() {
  late ObjectCreationSites sites;

  setUp(() => sites = ObjectCreationSites());

  test('take returns the recorded stack and removes it', () {
    final object = _A();
    final stack = StackTrace.current;
    sites.record(object, stack);
    expect(sites.length, 1);

    expect(sites.take(object), same(stack));
    expect(sites.take(object), isNull);
    expect(sites.length, 0);
  });

  test('take returns null for an object that was never recorded', () {
    sites.record(_A(), StackTrace.current);

    expect(sites.take(_A()), isNull);
    expect(sites.length, 1);
  });

  test('each object keeps its own stack', () {
    final first = _A();
    final second = _A();
    final firstStack = StackTrace.fromString('first');
    final secondStack = StackTrace.fromString('second');
    sites.record(first, firstStack);
    sites.record(second, secondStack);

    expect(sites.take(second), same(secondStack));
    expect(sites.take(first), same(firstStack));
  });

  test('recording an object that already has a stack keeps the first one', () {
    final object = _A();
    final firstStack = StackTrace.fromString('first');
    sites.record(object, firstStack);
    sites.record(object, StackTrace.fromString('second'));

    expect(sites.length, 1);
    expect(sites.take(object), same(firstStack));
  });

  test('pruneCollected keeps entries whose object is still alive', () {
    final object = _A();
    sites.record(object, StackTrace.current);

    sites.pruneCollected();

    expect(sites.length, 1);
    expect(sites.take(object), isNotNull);
  });

  test('pruneCollected drops entries whose object was garbage collected', () async {
    void recordTemporary() => sites.record(_A(), StackTrace.current);
    recordTemporary();
    expect(sites.length, 1);

    await forceGc();
    sites.pruneCollected();

    expect(sites.length, 0);
  });

  test('objects sharing a hash code are told apart by identity', () {
    final colliding = ObjectCreationSites(hashOf: (_) => 1);
    final first = _A();
    final second = _A();
    final firstStack = StackTrace.fromString('first');
    final secondStack = StackTrace.fromString('second');
    colliding.record(first, firstStack);
    colliding.record(second, secondStack);
    expect(colliding.length, 2);

    expect(colliding.take(second), same(secondStack));
    expect(colliding.take(second), isNull);
    expect(colliding.take(first), same(firstStack));
    expect(colliding.length, 0);
  });

  test('clear drops everything', () {
    sites.record(_A(), StackTrace.current);
    sites.record(_A(), StackTrace.current);

    sites.clear();

    expect(sites.length, 0);
  });
}
