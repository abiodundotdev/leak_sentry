import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/leak_sentry.dart';

void main() {
  test('toString shows member, uri, line and column', () {
    const site = CreationSite(uri: 'package:app/page.dart', member: '_PageState.initState', line: 42, column: 11);

    expect(site.toString(), '_PageState.initState (package:app/page.dart:42:11)');
  });

  test('toString leaves out whatever is unknown', () {
    expect(const CreationSite(uri: 'package:app/page.dart', line: 42, column: 11).toString(), 'package:app/page.dart:42:11');
    expect(const CreationSite(uri: 'package:app/page.dart', member: 'main', line: 42).toString(), 'main (package:app/page.dart:42)');
    expect(const CreationSite(uri: 'package:app/page.dart').toString(), 'package:app/page.dart');
  });
}
