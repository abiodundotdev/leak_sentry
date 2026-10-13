import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:leak_sentry/models/creation_site.dart';
import 'package:leak_sentry/ui/copy.dart';
import 'package:leak_sentry/ui/format.dart';
import 'package:leak_sentry/ui/tokens.dart';

/// One place in the source, with what it is the place of. Tapping it copies the
/// whole location (`package:app/main.dart:196:11`), ready to paste into an
/// editor's "go to file".
class SiteLine extends StatelessWidget {
  const SiteLine({super.key, required this.label, required this.site, this.isFallback = false});

  final String label;
  final CreationSite site;

  /// Whether this is not where the object was created but the next best place to look:
  /// it is drawn in the cautious colour, so that it is not taken for the real thing.
  final bool isFallback;

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: fullLocation(site)));
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text(LeakSentryCopy.locationCopied)));
  }

  @override
  Widget build(BuildContext context) {
    final member = site.member;
    final package = locationPackage(site);
    return Semantics(
      button: true,
      label: '$label ${fullLocation(site)}',
      hint: LeakSentryCopy.tapToCopy,
      onTap: () => _copy(context),
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _copy(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(fontSize: 12, color: LeakSentryColors.muted)),
                    const SizedBox(height: 2),
                    Text(
                      shortLocation(site),
                      style: LeakSentryText.mono(
                        size: 16,
                        color: isFallback ? LeakSentryColors.caution : LeakSentryColors.accent,
                        weight: FontWeight.w700,
                      ),
                    ),
                    if (member != null) Text(member, style: LeakSentryText.mono(size: 13, color: LeakSentryColors.text)),
                    if (package.isNotEmpty)
                      Text(package, style: LeakSentryText.mono(size: 11, color: LeakSentryColors.dim)),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(left: 8, top: 2),
                child: Icon(Icons.copy_rounded, size: 16, color: LeakSentryColors.dim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A place, small enough for a row of a list: an icon and the place, and under
/// it, when it has one, the function or class it is in.
class LocationPin extends StatelessWidget {
  const LocationPin({super.key, required this.text, this.detail, this.missing = false, this.fallback = false});

  final String text;

  /// What the place is in: `_PageThreeState.initState`.
  final String? detail;

  /// Whether the place is not known, which the text then says.
  final bool missing;

  /// Whether the place is the next best thing to where the object was created.
  final bool fallback;

  @override
  Widget build(BuildContext context) {
    final cautious = missing || fallback;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            missing ? Icons.help_outline_rounded : Icons.place_outlined,
            size: 14,
            color: cautious ? LeakSentryColors.caution : LeakSentryColors.accent,
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                text,
                style: LeakSentryText.mono(
                  size: 12,
                  color: cautious ? LeakSentryColors.caution : LeakSentryColors.text,
                  weight: FontWeight.w600,
                ),
              ),
              if (detail != null)
                Text(breakable(detail!, after: '.'), style: LeakSentryText.mono(size: 12, color: LeakSentryColors.muted)),
            ],
          ),
        ),
      ],
    );
  }
}
