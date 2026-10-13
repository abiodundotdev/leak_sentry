import 'package:leak_sentry/models/leak_report.dart';
import 'package:leak_sentry/models/object_finalizer.dart';
import 'package:leak_sentry/models/resource_token.dart';
import 'package:leak_sentry/utils/creation_site_util.dart';

/// Detects resources that are garbage collected without having been closed,
/// such as a `StreamController` nobody called `close()` on.
///
/// It needs none of the heap dump machinery: the garbage collector itself says
/// the resource is gone, so it works in release builds and on web.
class ResourceTracker {
  /// [finalizerFactory] builds the finalizer used internally, given the callback
  /// it must invoke on finalization. Tests inject a factory that builds a fake
  /// finalizer instead of the real, GC-timing-dependent one.
  ResourceTracker({
    required void Function(LeakReport report) onLeak,
    ObjectFinalizer<ResourceToken> Function(void Function(ResourceToken token))? finalizerFactory,
    bool? isWeb,
  }) : _onLeak = onLeak,
       _isWeb = isWeb {
    _finalizer = (finalizerFactory ?? RealObjectFinalizer<ResourceToken>.new)(_handleFinalized);
  }

  final void Function(LeakReport report) _onLeak;
  final bool? _isWeb;
  late final ObjectFinalizer<ResourceToken> _finalizer;

  /// Tracks [resource] for "garbage collected without being closed"
  /// detection. Call [ResourceToken.markClosed] on the returned token from the
  /// resource's real close path.
  ResourceToken trackResource(Object resource, {String? label}) {
    final token = ResourceToken(label ?? resource.runtimeType.toString(), type: resource.runtimeType);
    _finalizer.attach(resource, token);
    return token;
  }

  void _handleFinalized(ResourceToken token) {
    if (token.isClosed) return;
    final site = CreationSiteUtil.resolveWithReason(token.acquiredAt, type: token.type, isWeb: _isWeb);
    _onLeak(
      LeakReport(
        type: token.type,
        reason: token.label,
        firstObservedAt: token.createdAt,
        detectedAt: DateTime.now(),
        confidence: LeakConfidence.resourceNeverClosed,
        acquiredAt: token.acquiredAt,
        creationSite: site.site,
        creationSiteGap: site.gap,
        signature: '${token.type}|resourceNeverClosed|${token.label}',
      ),
    );
  }
}
