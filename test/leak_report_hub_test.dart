import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/core/leak_report_hub.dart';
import 'package:leak_sentry/models/leak_report.dart';

LeakReport _report(String signature, {int occurrences = 1}) => LeakReport(
  type: String,
  reason: signature,
  firstObservedAt: DateTime(2026),
  detectedAt: DateTime(2026),
  confidence: LeakConfidence.retainedAfterGc,
  signature: signature,
  occurrenceCount: occurrences,
);

void main() {
  late LeakReportHub hub;

  setUp(() => hub = LeakReportHub());

  test('a new leak is added, emitted, and remembered', () async {
    final emitted = <LeakReport>[];
    hub.leaks.listen(emitted.add);
    final report = _report('a');

    expect(hub.add(report), isTrue);
    await pumpEventQueue();

    expect(hub.leakHistory, [report]);
    expect(emitted, [report]);
  });

  test('a repeat adds to the count of the first report instead of emitting again', () async {
    final emitted = <LeakReport>[];
    hub.leaks.listen(emitted.add);
    final first = _report('a', occurrences: 2);

    hub.add(first);
    final added = hub.add(_report('a', occurrences: 3));
    await pumpEventQueue();

    expect(added, isFalse);
    expect(hub.leakHistory, [first]);
    expect(first.occurrenceCount, 5);
    expect(emitted, hasLength(1));
  });

  test('different signatures are different leaks', () {
    hub.add(_report('a'));
    hub.add(_report('b'));

    expect(hub.leakHistory.map((report) => report.signature), ['a', 'b']);
  });

  test('addAll says which signatures were new', () {
    hub.add(_report('a'));

    final added = hub.addAll([_report('a'), _report('b'), _report('c')]);

    expect(added, {'b', 'c'});
  });

  test('the history cannot be changed from outside', () {
    hub.add(_report('a'));

    expect(() => hub.leakHistory.clear(), throwsUnsupportedError);
  });

  test('expectNoLeaks passes with no leaks and fails, listing them, with some', () {
    expect(hub.expectNoLeaks, returnsNormally);

    hub.add(_report('a'));

    expect(
      hub.expectNoLeaks,
      throwsA(isA<StateError>().having((e) => e.message, 'message', allOf(contains('1 leak(s)'), contains('LeakReport(')))),
    );
  });

  test('clear forgets everything, so a leak can be reported as new again', () {
    hub.add(_report('a'));

    hub.clear();

    expect(hub.leakHistory, isEmpty);
    expect(hub.add(_report('a')), isTrue);
  });
}
