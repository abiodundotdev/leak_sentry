import 'package:flutter/material.dart';

/// The palette of the LeakSentry screens, "mint on slate": blue-grey surfaces,
/// a mint accent, and coral for what should be gone.
///
/// Every colour is written out as a constant instead of derived with
/// `withOpacity` or `withValues`, which differ between Flutter versions and
/// would put the screens' look at the mercy of the host app's SDK. Every
/// pairing of text on a surface it is used on has a contrast of at least 4.5:1,
/// and a test says so.
abstract final class LeakSentryColors {
  /// Behind everything.
  static const Color background = Color(0xFF0F141B);

  /// Cards and the navigation bar.
  static const Color surface = Color(0xFF161D27);

  /// A card on a card, or something being pressed.
  static const Color surfaceHigh = Color(0xFF1E2733);

  /// Hairlines and the rail of the trace timeline.
  static const Color outline = Color(0xFF2A3545);

  /// Text that matters.
  static const Color text = Color(0xFFE8EDF4);

  /// Text that supports it.
  static const Color muted = Color(0xFFA9B6C8);

  /// The faintest text there is. Still readable: no dimmer.
  static const Color dim = Color(0xFF8190A5);

  /// What can be acted on, and what is new.
  static const Color accent = Color(0xFF3DDCB2);

  /// A tint of the accent for a selected or highlighted background.
  static const Color accentDeep = Color(0xFF12362F);

  /// Text on the accent.
  static const Color onAccent = Color(0xFF06241D);

  /// Something that should be gone: the line and dots of the suspect span.
  static const Color danger = Color(0xFFFF7A85);

  /// A tint of the danger colour for a background.
  static const Color dangerDeep = Color(0xFF3A1D24);

  /// Text on [dangerDeep].
  static const Color dangerText = Color(0xFFFF9AA2);

  /// Something that is not known.
  static const Color caution = Color(0xFFF2B35E);

  /// A tint of [caution] for a background.
  static const Color cautionDeep = Color(0xFF3A2E17);

  /// Something that is in use, as it should be.
  static const Color inUse = Color(0xFF8FB6D9);

  /// A tint of [inUse] for a background.
  static const Color inUseDeep = Color(0xFF18283A);

  // Outlines of the pills, the accent and the status colours at about 40%.
  static const Color accentLine = Color(0x663DDCB2);
  static const Color dangerLine = Color(0x66FF7A85);
  static const Color cautionLine = Color(0x66F2B35E);
  static const Color inUseLine = Color(0x668FB6D9);
}

/// Sizes the screens share.
abstract final class LeakSentryMetrics {
  /// The widest the content is allowed to be. Beyond it, on a tablet or a
  /// desktop window, the content stays this wide and centred.
  static const double maxContentWidth = 640;

  /// The space around a page's content.
  static const double pagePadding = 16;

  /// The corners of a card.
  static const double cardRadius = 16;

  /// How far the floating navigation bar is from the edges.
  static const double navigationInset = 12;

  /// The corners of the floating navigation bar.
  static const double navigationRadius = 28;
}

/// Text styles for what is not ordinary text.
abstract final class LeakSentryText {
  /// The fonts a developer reads code in, tried in turn: none is bundled.
  static const List<String> monospaceFallback = ['Menlo', 'Roboto Mono', 'Courier New', 'Courier'];

  /// A class, a field or a file name.
  static TextStyle mono({double size = 13, Color color = LeakSentryColors.text, FontWeight? weight}) => TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: monospaceFallback,
    fontSize: size,
    height: 1.35,
    color: color,
    fontWeight: weight,
  );
}

/// The theme of the screens. They wear it whatever the host app's theme is, so
/// that they look the same everywhere and the app's colours can't make them
/// unreadable.
abstract final class LeakSentryTheme {
  static ThemeData data() {
    const scheme = ColorScheme.dark(
      primary: LeakSentryColors.accent,
      onPrimary: LeakSentryColors.onAccent,
      secondary: LeakSentryColors.accent,
      onSecondary: LeakSentryColors.onAccent,
      surface: LeakSentryColors.surface,
      onSurface: LeakSentryColors.text,
      error: LeakSentryColors.danger,
      onError: LeakSentryColors.onAccent,
      outline: LeakSentryColors.outline,
    );
    final base = ThemeData(brightness: Brightness.dark, useMaterial3: true, colorScheme: scheme);
    return base.copyWith(
      scaffoldBackgroundColor: LeakSentryColors.background,
      canvasColor: LeakSentryColors.background,
      dividerColor: LeakSentryColors.outline,
      dividerTheme: const DividerThemeData(color: LeakSentryColors.outline, space: 1, thickness: 1),
      splashFactory: InkRipple.splashFactory,
      textTheme: base.textTheme.apply(bodyColor: LeakSentryColors.text, displayColor: LeakSentryColors.text),
      appBarTheme: const AppBarTheme(
        backgroundColor: LeakSentryColors.background,
        foregroundColor: LeakSentryColors.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        // A hairline, so that content scrolled under the bar does not end in a hard cut.
        shape: Border(bottom: BorderSide(color: LeakSentryColors.outline)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: LeakSentryColors.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: LeakSentryColors.accentDeep,
        elevation: 0,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? LeakSentryColors.accent : LeakSentryColors.muted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
            color: states.contains(WidgetState.selected) ? LeakSentryColors.accent : LeakSentryColors.muted,
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? LeakSentryColors.onAccent : LeakSentryColors.muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? LeakSentryColors.accent : LeakSentryColors.outline,
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: LeakSentryColors.surfaceHigh,
        contentTextStyle: const TextStyle(color: LeakSentryColors.text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: LeakSentryColors.accent,
        linearTrackColor: LeakSentryColors.outline,
      ),
    );
  }
}
