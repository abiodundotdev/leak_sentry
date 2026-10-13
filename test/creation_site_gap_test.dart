import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/utils/creation_site_util.dart';

class _Leaky {}

/// Builds a stack trace in the Dart VM's text format from bare frames
/// (`member (uri:line:column)`).
StackTrace _stack(List<String> frames) =>
    StackTrace.fromString([for (var i = 0; i < frames.length; i++) '#$i      ${frames[i]}'].join('\n'));

CreationSiteResolution _resolve(
  StackTrace? stack, {
  bool isWeb = false,
  bool memoryAllocationsEnabled = true,
}) => CreationSiteUtil.resolveWithReason(
  stack,
  type: _Leaky,
  isWeb: isWeb,
  memoryAllocationsEnabled: memoryAllocationsEnabled,
);

void main() {
  group('a creation site that is found', () {
    test('comes with no reason', () {
      final resolution = _resolve(_stack(['_PageState.initState (package:app/page.dart:42:11)']));

      expect(resolution.site?.member, '_PageState.initState');
      expect(resolution.site?.line, 42);
      expect(resolution.gap, isNull);
    });

    test('is the same one resolve finds', () {
      final stack = _stack([
        'FlutterMemoryAllocations.dispatchObjectEvent (package:flutter/src/foundation/memory_allocations.dart:243:23)',
        'new _Leaky (package:app/leaky.dart:5:3)',
        '_PageState.initState (package:app/page.dart:42:11)',
      ]);

      final site = CreationSiteUtil.resolve(stack, type: _Leaky);

      expect(_resolve(stack).site?.toString(), site?.toString());
      expect(site?.member, '_PageState.initState');
    });
  });

  group('no creation site, and why', () {
    test('a State that has no initState of its own: Flutter announces it from inside its own code', () {
      final resolution = _resolve(
        _stack([
          'FlutterMemoryAllocations.dispatchObjectEvent (package:flutter/src/foundation/memory_allocations.dart:243:23)',
          'State.initState (package:flutter/src/widgets/framework.dart:1010:12)',
          'StatefulElement._firstBuild (package:flutter/src/widgets/framework.dart:5950:55)',
          'ComponentElement.mount (package:flutter/src/widgets/framework.dart:5793:5)',
          'Element.inflateWidget (dart:ui/something.dart:10:1)',
        ]),
      );

      expect(resolution.site, isNull);
      expect(resolution.gap, CreationSiteGap.onlyFrameworkFrames);
    });

    test('the only application frame is the constructor of the object itself', () {
      final resolution = _resolve(
        _stack([
          'new _Leaky (package:app/leaky.dart:5:3)',
          'StatefulElement._firstBuild (package:flutter/src/widgets/framework.dart:5950:55)',
        ]),
      );

      expect(resolution.gap, CreationSiteGap.onlyFrameworkFrames);
    });

    test('a frame with no line cannot be shown', () {
      final resolution = _resolve(_stack(['_PageState.initState (package:app/page.dart)']));

      expect(resolution.gap, CreationSiteGap.onlyFrameworkFrames);
    });

    test('an object Flutter never reported being created, in a build that reports creation', () {
      expect(_resolve(null).gap, CreationSiteGap.notAnnounced);
    });

    test('an object in a build that reports no creation at all', () {
      expect(_resolve(null, memoryAllocationsEnabled: false).gap, CreationSiteGap.notDebugBuild);
    });

    test('the web has stacks that name no Dart source, whatever the stack says', () {
      final resolution = _resolve(_stack(['_PageState.initState (package:app/page.dart:42:11)']), isWeb: true);

      expect(resolution.site, isNull);
      expect(resolution.gap, CreationSiteGap.web);
      expect(_resolve(null, isWeb: true).gap, CreationSiteGap.web);
    });

    test('a stack of an app built with --split-debug-info has offsets and no names', () {
      final resolution = _resolve(
        StackTrace.fromString(
          '*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***\n'
          "build_id: '0123abcd'\n"
          'isolate_dso_base: 7f1c2d000000, vm_dso_base: 7f1c2d000000\n'
          'isolate_instructions: 7f1c2d1a0000, vm_instructions: 7f1c2d180000\n'
          '    #00 abs 00007f1c2d4b6c3f virt 00000000012b6c3f _kDartIsolateSnapshotInstructions+0x316c3f\n',
        ),
      );

      expect(resolution.site, isNull);
      expect(resolution.gap, CreationSiteGap.symbolless);
    });

    test('text that is no stack trace at all', () {
      expect(_resolve(StackTrace.fromString('this is not a stack trace')).gap, CreationSiteGap.unparseable);
    });

    test('an empty stack', () {
      expect(_resolve(StackTrace.fromString('')).gap, CreationSiteGap.unparseable);
    });

    test('resolve gives nothing in every one of these cases', () {
      for (final stack in <StackTrace?>[
        null,
        StackTrace.fromString(''),
        StackTrace.fromString('this is not a stack trace'),
        _stack(['State.initState (package:flutter/src/widgets/framework.dart:1010:12)']),
      ]) {
        expect(CreationSiteUtil.resolve(stack, type: _Leaky), isNull);
      }
    });
  });
}
