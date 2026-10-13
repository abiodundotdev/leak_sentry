import 'package:leak_sentry/core/leak_catalog.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/format.dart';

/// Where to start looking for a leak, as a row of the leaks list says it.
///
/// A leak always has an answer: where its object was created, else where it was
/// handed to the watcher, else where its class is declared, else that it is not
/// known (and the detail screen says why).
class SiteSummary {
  const SiteSummary({
    required this.label,
    required this.text,
    this.place = '',
    this.member,
    this.isMissing = false,
    this.otherSites = 0,
  });

  /// What the place is the place of: "Created at", "Watched at", ...
  final String label;

  /// The place: `main.dart:196 · _PageThreeState.initState`. Empty when it is missing.
  final String text;

  /// The file and line of it: `main.dart:196`. Empty when it is missing.
  final String place;

  /// The function or class it is in: `_PageThreeState.initState`.
  final String? member;

  /// Whether nothing is known about where the leak came from.
  final bool isMissing;

  /// How many other places the leak's other instances came from.
  final int otherSites;

  /// Whether the place is not where the object was created but the next best thing: where
  /// it was handed to the watcher, or where its class is declared.
  bool get isFallback => label == LeakSentryCopy.watchedAt || label == LeakSentryCopy.classDeclaredAt;
}

/// The place [group] is best looked for at: the one its latest instance came from.
SiteSummary summarizeSite(LeakGroup group) {
  final primary = group.instances.reduce((best, next) => next.lastSeen.isAfter(best.lastSeen) ? next : best);
  final key = _siteKeyOf(primary);
  final others = {
    for (final instance in group.instances)
      if (instance != primary) _siteKeyOf(instance),
  }..remove(key);
  return summarizeSites(
    created: primary.creationSite,
    watched: primary.watchSite,
    declared: primary.classSite,
    isResource: group.kind == LeakKind.resource,
    otherSites: others.length,
  );
}

/// The best place to start looking, out of what is known: where the object was
/// created, else where it was handed to the watcher, else where its class is
/// declared, else that none is known.
SiteSummary summarizeSites({
  CreationSite? created,
  CreationSite? watched,
  CreationSite? declared,
  bool isResource = false,
  int otherSites = 0,
}) {
  if (created != null) {
    final label = isResource ? LeakSentryCopy.acquiredAt : LeakSentryCopy.createdAt;
    return _summary(label, created, otherSites);
  }
  if (watched != null) return _summary(LeakSentryCopy.watchedAt, watched, otherSites);
  if (declared != null) return _summary(LeakSentryCopy.classDeclaredAt, declared, otherSites);
  return SiteSummary(label: LeakSentryCopy.creationUnknown, text: '', isMissing: true, otherSites: otherSites);
}

SiteSummary _summary(String label, CreationSite site, int otherSites) => SiteSummary(
  label: label,
  text: _describe(site),
  place: shortLocation(site),
  member: site.member,
  otherSites: otherSites,
);

/// What a row says about where a leak came from: the place, and what it is in on a line of its
/// own. Where the object was created needs no label: the pin says it is a place.
({String place, String? member}) describePinParts(SiteSummary site) {
  if (site.isMissing) return (place: LeakSentryCopy.creationUnknown, member: null);
  final place = site.label == LeakSentryCopy.createdAt ? site.place : '${site.label.toLowerCase()} ${site.place}';
  return (place: site.otherSites > 0 ? '$place  ${LeakSentryCopy.otherPlaces(site.otherSites)}' : place, member: site.member);
}

/// `main.dart:196 · _PageThreeState.initState`.
String _describe(CreationSite site) {
  final member = site.member;
  return member == null ? shortLocation(site) : '${shortLocation(site)} · $member';
}

String _siteKeyOf(LeakInstance instance) {
  final site = instance.creationSite ?? instance.watchSite ?? instance.classSite;
  return site == null ? '' : fullLocation(site);
}
