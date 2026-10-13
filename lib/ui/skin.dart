import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:leak_sentry/ui/tokens.dart';

/// Dresses everything below it in the look of the LeakSentry screens, whatever
/// the app they are shown in looks like.
///
/// The screens bring their own theme, their own English localizations and their
/// own status bar style, so that an app with a light theme, a different
/// language, or no Material at all (just a `WidgetsApp`) gets the same screens,
/// and they never ask the app for something it does not have.
class LeakSentrySkin extends StatelessWidget {
  const LeakSentrySkin({super.key, required this.child});

  final Widget child;

  static final ThemeData _theme = LeakSentryTheme.data();

  @override
  Widget build(BuildContext context) {
    return Localizations(
      locale: const Locale('en', 'US'),
      delegates: const [DefaultWidgetsLocalizations.delegate, DefaultMaterialLocalizations.delegate],
      child: Theme(
        data: _theme,
        // Its own messenger: the screens' snack bars work in an app that has none.
        child: ScaffoldMessenger(
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light,
            child: child,
          ),
        ),
      ),
    );
  }
}
