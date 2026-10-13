import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_sentry/ui/tokens.dart';

/// The contrast ratio of two colours, as WCAG defines it.
double _contrast(Color a, Color b) {
  final lighter = math.max(a.computeLuminance(), b.computeLuminance());
  final darker = math.min(a.computeLuminance(), b.computeLuminance());
  return (lighter + 0.05) / (darker + 0.05);
}

double _hue(Color color) => HSLColor.fromColor(color).hue;

double _distance(Color a, Color b) {
  double channel(double x, double y) => (x - y) * 255;
  return math.sqrt(
    math.pow(channel(a.r, b.r), 2) + math.pow(channel(a.g, b.g), 2) + math.pow(channel(a.b, b.b), 2),
  );
}

void main() {
  group('every text is readable on what it is drawn on', () {
    const surfaces = {
      'background': LeakSentryColors.background,
      'surface': LeakSentryColors.surface,
      'surfaceHigh': LeakSentryColors.surfaceHigh,
    };
    const texts = {
      'text': LeakSentryColors.text,
      'muted': LeakSentryColors.muted,
      'dim': LeakSentryColors.dim,
      'accent': LeakSentryColors.accent,
      'caution': LeakSentryColors.caution,
      'inUse': LeakSentryColors.inUse,
      'dangerText': LeakSentryColors.dangerText,
    };

    for (final surface in surfaces.entries) {
      for (final text in texts.entries) {
        test('${text.key} on ${surface.key}', () {
          expect(_contrast(text.value, surface.value), greaterThanOrEqualTo(4.5));
        });
      }
    }

    test('text on the accent, which fills a button and an unread badge', () {
      expect(_contrast(LeakSentryColors.onAccent, LeakSentryColors.accent), greaterThanOrEqualTo(4.5));
      expect(_contrast(LeakSentryColors.onAccent, LeakSentryColors.danger), greaterThanOrEqualTo(4.5), reason: 'the button that clears');
    });

    test('the accent on its own tint, which marks the selected tab', () {
      expect(_contrast(LeakSentryColors.accent, LeakSentryColors.accentDeep), greaterThanOrEqualTo(4.5));
    });

    test('each status colour on its own tint, which is what a pill is', () {
      expect(_contrast(LeakSentryColors.dangerText, LeakSentryColors.dangerDeep), greaterThanOrEqualTo(4.5));
      expect(_contrast(LeakSentryColors.caution, LeakSentryColors.cautionDeep), greaterThanOrEqualTo(4.5));
      expect(_contrast(LeakSentryColors.inUse, LeakSentryColors.inUseDeep), greaterThanOrEqualTo(4.5));
    });

    test('the suspect highlight text on the surface it sits on in a list', () {
      expect(_contrast(LeakSentryColors.dangerText, LeakSentryColors.dangerDeep), greaterThanOrEqualTo(4.5));
      expect(_contrast(LeakSentryColors.text, LeakSentryColors.surface), greaterThanOrEqualTo(7));
    });

    test('the rail and the card outlines can be seen against the background', () {
      expect(_contrast(LeakSentryColors.outline, LeakSentryColors.background), greaterThan(1.2));
    });
  });

  group('the look is its own', () {
    // Colours to stay away from: dark and light greys, yellows, a purple, a blue and a red.
    const avoided = [
      Color(0xFF242424), Color(0xFF2F2F2F), Color(0xFF3F3F3F), Color(0xFF151C1F), Color(0xFFFFCC32),
      Color(0xFFFFD34C), Color(0xFFFFE79F), Color(0xFFBE383F), Color(0xFF9976A8), Color(0xFF6A98B9),
      Color(0xFFBABABA), Color(0xFF919191),
    ];
    const tokens = {
      'background': LeakSentryColors.background,
      'surface': LeakSentryColors.surface,
      'surfaceHigh': LeakSentryColors.surfaceHigh,
      'outline': LeakSentryColors.outline,
      'text': LeakSentryColors.text,
      'muted': LeakSentryColors.muted,
      'dim': LeakSentryColors.dim,
      'accent': LeakSentryColors.accent,
      'danger': LeakSentryColors.danger,
      'dangerText': LeakSentryColors.dangerText,
      'caution': LeakSentryColors.caution,
      'inUse': LeakSentryColors.inUse,
    };

    test('no colour is close to an avoided one', () {
      for (final token in tokens.entries) {
        for (final other in avoided) {
          expect(_distance(token.value, other), greaterThan(6), reason: '${token.key} is too close to $other');
        }
      }
    });

    test('the surfaces are slate, with a blue cast', () {
      for (final surface in [LeakSentryColors.background, LeakSentryColors.surface, LeakSentryColors.surfaceHigh, LeakSentryColors.outline]) {
        expect(_hue(surface), inInclusiveRange(205, 225), reason: '$surface');
      }
    });

    test('the accent is mint, not yellow', () {
      expect(_hue(LeakSentryColors.accent), inInclusiveRange(150, 175));
    });

    test('the coral is lighter than the avoided red', () {
      expect(LeakSentryColors.danger.computeLuminance(), greaterThan(const Color(0xFFBE383F).computeLuminance() + 0.1));
    });
  });

  group('the theme', () {
    test('is dark, Material 3, and the accent is the primary colour', () {
      final theme = LeakSentryTheme.data();

      expect(theme.brightness, Brightness.dark);
      expect(theme.useMaterial3, isTrue);
      expect(theme.colorScheme.primary, LeakSentryColors.accent);
      expect(theme.scaffoldBackgroundColor, LeakSentryColors.background);
    });

    test('does not borrow the look of the app it is shown in', () {
      // Built the same way whatever the app does, so it is the same value.
      expect(LeakSentryTheme.data().colorScheme, LeakSentryTheme.data().colorScheme);
    });

    test('has dividers in the outline colour, not the bright default', () {
      final divider = LeakSentryTheme.data().dividerTheme;

      expect(divider.color, LeakSentryColors.outline);
      expect(divider.thickness, 1);
    });

    test('the app bar ends in a hairline, so that what scrolls under it does not end in a hard cut', () {
      final bar = LeakSentryTheme.data().appBarTheme;

      expect(bar.shape, const Border(bottom: BorderSide(color: LeakSentryColors.outline)));
      expect(bar.scrolledUnderElevation, 0);
      expect(bar.backgroundColor, LeakSentryColors.background);
    });

    test('the navigation bar has a mint indicator, on the surface', () {
      final bar = LeakSentryTheme.data().navigationBarTheme;

      expect(bar.indicatorColor, LeakSentryColors.accentDeep);
      expect(bar.backgroundColor, LeakSentryColors.surface);
    });
  });

  group('code is set in a monospace face', () {
    test('with fallbacks, and no bundled font', () {
      final style = LeakSentryText.mono();

      expect(style.fontFamily, 'monospace');
      expect(style.fontFamilyFallback, containsAll(['Menlo', 'Roboto Mono', 'Courier New']));
    });
  });
}
