import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/utils/creation_site_util.dart';

class _Leaky<T> {}

Type _typeOf<T>() => T;

/// Builds a stack trace in the Dart VM's text format from bare frames
/// (`member (uri:line:column)`).
StackTrace _stack(List<String> frames) =>
    StackTrace.fromString([for (var i = 0; i < frames.length; i++) '#$i      ${frames[i]}'].join('\n'));

void main() {
  test('returns the first application frame after leak_sentry, Flutter and own-constructor frames', () {
    final site = CreationSiteUtil.resolve(
      _stack([
        'LeakTracker.start.<fn> (package:leak_sentry/models/leak_tracker.dart:120:15)',
        'FlutterMemoryAllocations.dispatchObjectEvent (package:flutter/src/foundation/memory_allocations.dart:243:23)',
        'new ValueNotifier (package:flutter/src/foundation/change_notifier.dart:546:22)',
        'new _Leaky (package:app/leaky.dart:5:3)',
        '_PageState.initState (package:app/page.dart:42:11)',
        'StatefulElement._firstBuild (package:flutter/src/widgets/framework.dart:5800:55)',
      ]),
      type: _Leaky,
    );

    expect(site, isNotNull);
    expect(site!.member, '_PageState.initState');
    expect(site.uri, 'package:app/page.dart');
    expect(site.line, 42);
    expect(site.column, 11);
    expect(site.toString(), '_PageState.initState (package:app/page.dart:42:11)');
  });

  test('skips named constructors of the object\'s own type', () {
    final site = CreationSiteUtil.resolve(
      _stack([
        'new _Leaky.named (package:app/leaky.dart:7:3)',
        '_PageState.initState (package:app/page.dart:42:11)',
      ]),
      type: _Leaky,
    );

    expect(site!.member, '_PageState.initState');
  });

  test('matches the own constructor regardless of the type\'s type arguments', () {
    final site = CreationSiteUtil.resolve(
      _stack([
        'new _Leaky (package:app/leaky.dart:5:3)',
        '_PageState.initState (package:app/page.dart:42:11)',
      ]),
      type: _typeOf<_Leaky<int>>(),
    );

    expect(site!.member, '_PageState.initState');
  });

  test('keeps constructor frames of other types, since a field initializer runs inside the enclosing constructor', () {
    final site = CreationSiteUtil.resolve(
      _stack([
        'new _Leaky (package:app/leaky.dart:5:3)',
        'new _Holder (package:app/holder.dart:11:13)',
        'main (package:app/main.dart:3:3)',
      ]),
      type: _Leaky,
    );

    expect(site!.member, 'new _Holder');
    expect(site.line, 11);
    expect(site.column, 13);
  });

  test('skips frames without a line number', () {
    final site = CreationSiteUtil.resolve(
      _stack([
        'new _Base (package:app/base.dart)',
        '_PageState.initState (package:app/page.dart:42:11)',
      ]),
      type: _Leaky,
    );

    expect(site!.member, '_PageState.initState');
  });

  test('skips dart: frames', () {
    final site = CreationSiteUtil.resolve(
      _stack([
        '_rootRun (dart:async/zone.dart:1399:13)',
        '_PageState.initState (package:app/page.dart:42:11)',
      ]),
      type: _Leaky,
    );

    expect(site!.member, '_PageState.initState');
  });

  test('skips flutter_test and test_api frames', () {
    final site = CreationSiteUtil.resolve(
      _stack([
        'testWidgets.<fn>.<fn> (package:flutter_test/src/widget_tester.dart:200:5)',
        'Declarer.test.<fn> (package:test_api/src/backend/declarer.dart:100:3)',
        '_PageState.initState (package:app/page.dart:42:11)',
      ]),
      type: _Leaky,
    );

    expect(site!.member, '_PageState.initState');
  });

  test('returns null for the JavaScript stack formats of web builds', () {
    final v8 = StackTrace.fromString(
      'Error\n'
      '    at Object.StackTrace_current (https://host/main.dart.js:1234:56)\n'
      '    at LeakTracker.start.<anonymous> (https://host/main.dart.js:100:5)',
    );
    final firefox = StackTrace.fromString(
      'StackTrace_current@https://host/main.dart.js:1234:56\n'
      'start/<@https://host/main.dart.js:100:5',
    );

    expect(CreationSiteUtil.resolve(v8, type: _Leaky), isNull);
    expect(CreationSiteUtil.resolve(firefox, type: _Leaky), isNull);
  });

  test('returns null when every frame is framework code', () {
    final site = CreationSiteUtil.resolve(
      _stack([
        'new ValueNotifier (package:flutter/src/foundation/change_notifier.dart:546:22)',
        'StatefulElement._firstBuild (package:flutter/src/widgets/framework.dart:5800:55)',
        'runApp (package:flutter/src/widgets/binding.dart:1:1)',
      ]),
      type: _Leaky,
    );

    expect(site, isNull);
  });

  test('returns null for a null stack, an empty stack, and unparseable text', () {
    expect(CreationSiteUtil.resolve(null, type: _Leaky), isNull);
    expect(CreationSiteUtil.resolve(StackTrace.fromString(''), type: _Leaky), isNull);
    expect(CreationSiteUtil.resolve(StackTrace.fromString('this is not a stack trace'), type: _Leaky), isNull);
  });

  test('resolves a real stack trace to the test that captured it', () {
    final site = CreationSiteUtil.resolve(StackTrace.current, type: _Leaky);

    expect(site, isNotNull);
    expect(site!.uri, endsWith('creation_site_util_test.dart'));
    expect(site.line, isNotNull);
  });
}
