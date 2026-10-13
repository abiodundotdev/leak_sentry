import 'package:flutter/foundation.dart' show kFlutterMemoryAllocationsEnabled, kIsWeb;
import 'package:leak_sentry/models/creation_site.dart';
import 'package:stack_trace/stack_trace.dart';

/// A creation site, or the reason there isn't one. See
/// [CreationSiteUtil.resolveWithReason].
class CreationSiteResolution {
  const CreationSiteResolution.found(CreationSite this.site) : gap = null;

  const CreationSiteResolution.missing(CreationSiteGap this.gap) : site = null;

  /// The site, when one was found.
  final CreationSite? site;

  /// Why there is no site, when none was found.
  final CreationSiteGap? gap;
}

/// Picks the line of application code responsible for creating an object
/// out of a stack trace captured while it was being created or tracked.
class CreationSiteUtil {
  CreationSiteUtil._();

  /// Packages whose frames are infrastructure, not the code that created
  /// the object.
  static const Set<String> _skippedPackages = {'flutter', 'flutter_test', 'test_api', 'leak_sentry'};

  /// URI schemes of source files in the Dart VM's stack trace format. Frames
  /// in any other scheme (`dart:` SDK code, or the `http(s):` JavaScript
  /// frames of web builds) are never application code.
  static const Set<String> _sourceSchemes = {'package', 'file', 'org-dartlang-app'};

  /// The first frame of [stack] that is in application source (see
  /// [_sourceSchemes]), isn't Flutter, test-framework or `leak_sentry` code,
  /// isn't a constructor of the object's own [type] (those just name the
  /// class, not who instantiated it), and has a line number. `null` if
  /// [stack] is `null`, unparseable, or has no such frame, and always on
  /// web, where stack traces don't map to Dart source.
  ///
  /// Constructors of *other* types are kept on purpose: a field initializer
  /// like `final controller = FooController();` runs inside the enclosing
  /// class's constructor, and that frame carries the line of the initializer.
  static CreationSite? resolve(StackTrace? stack, {required Type type}) => resolveWithReason(stack, type: type).site;

  /// Like [resolve], and when there is no site it says why.
  ///
  /// [isWeb] and [memoryAllocationsEnabled] stand for `kIsWeb` and
  /// `kFlutterMemoryAllocationsEnabled`, which tests can't change.
  static CreationSiteResolution resolveWithReason(
    StackTrace? stack, {
    required Type type,
    bool? isWeb,
    bool? memoryAllocationsEnabled,
  }) {
    if (isWeb ?? kIsWeb) return const CreationSiteResolution.missing(CreationSiteGap.web);
    if (stack == null) {
      return CreationSiteResolution.missing(
        (memoryAllocationsEnabled ?? kFlutterMemoryAllocationsEnabled)
            ? CreationSiteGap.notAnnounced
            : CreationSiteGap.notDebugBuild,
      );
    }
    try {
      if (_hasNoSymbols(stack)) return const CreationSiteResolution.missing(CreationSiteGap.symbolless);
      final frames = Trace.from(stack).frames;
      // Text the parser could not read comes back as frames that are not frames.
      if (frames.isEmpty || frames.every((frame) => frame is UnparsedFrame)) {
        return const CreationSiteResolution.missing(CreationSiteGap.unparseable);
      }
      final typeName = _bareName(type);
      for (final frame in frames) {
        if (!_sourceSchemes.contains(frame.uri.scheme) || _skippedPackages.contains(frame.package)) continue;
        if (frame.line == null || _isOwnConstructor(frame.member, typeName)) continue;
        return CreationSiteResolution.found(
          CreationSite(uri: frame.uri.toString(), member: frame.member, line: frame.line, column: frame.column),
        );
      }
      return const CreationSiteResolution.missing(CreationSiteGap.onlyFrameworkFrames);
    } catch (_) {
      // Stack trace text is platform-specific; an unexpected format must
      // never be able to break leak reporting.
      return const CreationSiteResolution.missing(CreationSiteGap.unparseable);
    }
  }

  /// A stack trace of an app built with `--split-debug-info` names no function
  /// and no file, only offsets into the program, and starts with a banner.
  static bool _hasNoSymbols(StackTrace stack) {
    final text = stack.toString();
    return text.contains('isolate_dso_base') || text.contains('*** *** ***');
  }

  static bool _isOwnConstructor(String? member, String typeName) =>
      member != null && (member == 'new $typeName' || member.startsWith('new $typeName.'));

  static String _bareName(Type type) {
    final name = type.toString();
    final typeArguments = name.indexOf('<');
    return typeArguments < 0 ? name : name.substring(0, typeArguments);
  }
}
