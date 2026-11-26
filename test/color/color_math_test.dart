import 'package:flutter/painting.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/color/color_math.dart';
import 'package:lumen/domain/light.dart';

void main() {
  test('pure sRGB primaries map near their xy chromaticities', () {
    final red = ColorMath.rgbToXy(const Color(0xFFFF0000));
    expect(red.x, closeTo(0.64, 0.01));
    expect(red.y, closeTo(0.33, 0.01));
    final green = ColorMath.rgbToXy(const Color(0xFF00FF00));
    expect(green.x, closeTo(0.30, 0.01));
    expect(green.y, closeTo(0.60, 0.01));
  });

  test('white maps to D65', () {
    final white = ColorMath.rgbToXy(const Color(0xFFFFFFFF));
    expect(white.x, closeTo(0.3127, 0.002));
    expect(white.y, closeTo(0.3290, 0.002));
  });

  test('xy round trips through rgb for in-gamut colours', () {
    for (final c in [const Color(0xFFFF8800), const Color(0xFF2266FF), const Color(0xFF66FF99)]) {
      final back = ColorMath.xyToRgb(ColorMath.rgbToXy(c));
      final hsvIn = HSVColor.fromColor(c);
      final hsvOut = HSVColor.fromColor(back);
      expect(hsvOut.hue, closeTo(hsvIn.hue, 2));
      expect(hsvOut.saturation, closeTo(hsvIn.saturation, 0.03));
    }
  });

  test('xy to rgb is always a valid, full brightness colour', () {
    final c = ColorMath.xyToRgb(const XyColor(0.7, 0.29));
    final max = [c.r, c.g, c.b].reduce((a, b) => a > b ? a : b);
    expect(max, closeTo(1.0, 0.001));
  });

  test('mireds convert to kelvin and to a warm or cool preview colour', () {
    expect(const WhiteColor(500).kelvin, 2000);
    expect(const WhiteColor(153).kelvin, 6536);
    final warm = ColorMath.miredsToRgb(500);
    final cool = ColorMath.miredsToRgb(153);
    expect(warm.r, greaterThan(warm.b));
    expect(cool.b, greaterThan(warm.b));
  });

  test('a colour temperature above 6600 K previews blue-white, with full blue', () {
    final daylight = ColorMath.miredsToRgb(100);
    expect((daylight.b * 255).round(), 255);
    expect(daylight.r, lessThan(daylight.b));
    expect(daylight.g, lessThan(daylight.b));
    expect(daylight.r, greaterThan(0.5));
  });

  test('colorOf previews xy, white and an unknown colour', () {
    const xy = XyColor(0.2, 0.25);
    expect(ColorMath.colorOf(xy), ColorMath.xyToRgb(xy));
    expect(ColorMath.colorOf(const WhiteColor(250)), ColorMath.miredsToRgb(250));
    expect(ColorMath.colorOf(null), ColorMath.miredsToRgb(366), reason: 'no colour previews a warm white');
  });

  test('wheel position and colour are inverse of each other', () {
    const xy = XyColor(0.2, 0.25);
    final (hue, sat) = ColorMath.xyToHueSat(xy);
    final back = ColorMath.hueSatToXy(hue, sat);
    expect(back.x, closeTo(xy.x, 0.01));
    expect(back.y, closeTo(xy.y, 0.01));
  });

  test('display colour reflects the state, dark when off', () {
    final off = ColorMath.displayColor(const LightState(on: false, color: XyColor(0.6, 0.3)));
    final on = ColorMath.displayColor(const LightState(on: true, brightness: 254, color: XyColor(0.6, 0.3)));
    expect(on.r, greaterThan(on.b));
    expect(off.computeLuminance(), lessThan(on.computeLuminance()));
  });

  test('clamps xy into a lamp gamut', () {
    final clamped = ColorMath.clampToGamut(const XyColor(0.1, 0.9), Gamut.c);
    expect(Gamut.c.contains(clamped), isTrue);
    expect(Gamut.c.contains(const XyColor(0.3, 0.3)), isTrue);
  });
}
