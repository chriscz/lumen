// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../domain/light.dart';

/// A lamp's colour gamut: the triangle of xy points it can reproduce.
class Gamut {
  const Gamut(this.red, this.green, this.blue);

  final XyColor red;
  final XyColor green;
  final XyColor blue;

  /// Gamut C, used by every current Hue colour bulb.
  static const c = Gamut(XyColor(0.6915, 0.3083), XyColor(0.17, 0.7), XyColor(0.1532, 0.0475));

  bool contains(XyColor p) {
    double side(XyColor a, XyColor b) => (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
    final d1 = side(red, green), d2 = side(green, blue), d3 = side(blue, red);
    const eps = 1e-9;
    final hasNeg = d1 < -eps || d2 < -eps || d3 < -eps;
    final hasPos = d1 > eps || d2 > eps || d3 > eps;
    return !(hasNeg && hasPos);
  }
}

/// Conversions between screen colours, CIE xy and colour temperature.
abstract final class ColorMath {
  static double _expand(double c) => c > 0.04045 ? math.pow((c + 0.055) / 1.055, 2.4).toDouble() : c / 12.92;

  static double _compress(double c) => c <= 0.0031308 ? 12.92 * c : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;

  static XyColor rgbToXy(Color color) {
    final r = _expand(color.r), g = _expand(color.g), b = _expand(color.b);
    final x = 0.4124 * r + 0.3576 * g + 0.1805 * b;
    final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    final z = 0.0193 * r + 0.1192 * g + 0.9505 * b;
    final sum = x + y + z;
    if (sum <= 0) return const XyColor(0.3127, 0.3290);
    return XyColor(x / sum, y / sum);
  }

  /// The xy colour at full brightness, as a screen colour.
  static Color xyToRgb(XyColor xy) {
    final y = math.max(xy.y, 1e-4);
    const bigY = 1.0;
    final bigX = (bigY / y) * xy.x;
    final bigZ = (bigY / y) * (1 - xy.x - xy.y);
    var r = 3.2406 * bigX - 1.5372 * bigY - 0.4986 * bigZ;
    var g = -0.9689 * bigX + 1.8758 * bigY + 0.0415 * bigZ;
    var b = 0.0557 * bigX - 0.2040 * bigY + 1.0570 * bigZ;
    r = math.max(r, 0);
    g = math.max(g, 0);
    b = math.max(b, 0);
    final m = math.max(r, math.max(g, b));
    if (m <= 0) return const Color(0xFFFFFFFF);
    r = _compress(r / m);
    g = _compress(g / m);
    b = _compress(b / m);
    final m2 = math.max(r, math.max(g, b));
    return Color.from(alpha: 1, red: r / m2, green: g / m2, blue: b / m2);
  }

  /// Black body colour for a temperature in mireds, after Tanner Helland.
  static Color miredsToRgb(int mireds) {
    final t = (1000000 / mireds) / 100;
    double r, g, b;
    if (t <= 66) {
      r = 255;
      g = 99.4708025861 * math.log(t) - 161.1195681661;
      b = t <= 19 ? 0 : 138.5177312231 * math.log(t - 10) - 305.0447927307;
    } else {
      r = 329.698727446 * math.pow(t - 60, -0.1332047592);
      g = 288.1221695283 * math.pow(t - 60, -0.0755148492);
      b = 255;
    }
    int c(double v) => v.clamp(0, 255).round();
    return Color.fromARGB(255, c(r), c(g), c(b));
  }

  /// Hue in degrees and saturation 0..1, as on the colour wheel.
  static (double, double) xyToHueSat(XyColor xy) {
    final hsv = HSVColor.fromColor(xyToRgb(xy));
    return (hsv.hue, hsv.saturation);
  }

  static XyColor hueSatToXy(double hue, double saturation) =>
      rgbToXy(HSVColor.fromAHSV(1, hue % 360, saturation.clamp(0, 1), 1).toColor());

  static Color colorOf(LightColor? color) => switch (color) {
    final XyColor xy => xyToRgb(xy),
    WhiteColor(:final mireds) => miredsToRgb(mireds),
    null => miredsToRgb(HueRange.defaultMireds),
  };

  /// How the light looks right now, for tiles and previews.
  static Color displayColor(LightState state) {
    const off = Color(0xFF2A2A30);
    if (!(state.on ?? false)) return off;
    final base = colorOf(state.color);
    final level = 0.35 + 0.65 * ((state.brightness ?? 254) / 254);
    return Color.lerp(off, base, level)!;
  }

  /// The nearest white for an xy colour, by McCamy's approximation.
  static int xyToMireds(XyColor xy) {
    final n = (xy.x - 0.3320) / (0.1858 - xy.y);
    final cct = 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33;
    if (cct <= 0) return HueRange.maxMireds;
    return HueRange.mireds((1000000 / cct).round());
  }

  /// [state] as a light of [kind] can show it, and whether it had to change.
  static (LightState, bool) adapt(LightState state, LightKind kind) {
    switch (state.color) {
      case final XyColor xy when !kind.hasColor && kind.hasTemperature:
        return (_withColor(state, WhiteColor(xyToMireds(xy))), true);
      case final LightColor _ when !kind.hasTemperature:
        return (_withColor(state, null), true);
      default:
        return (state, false);
    }
  }

  static LightState _withColor(LightState s, LightColor? color) =>
      LightState(on: s.on, brightness: s.brightness, color: color, effect: s.effect, effectSpeed: s.effectSpeed);

  static XyColor clampToGamut(XyColor p, Gamut g) {
    if (g.contains(p)) return p;
    XyColor closest(XyColor a, XyColor b) {
      final dx = b.x - a.x, dy = b.y - a.y;
      final t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)).clamp(0.0, 1.0);
      return XyColor(a.x + t * dx, a.y + t * dy);
    }

    double dist(XyColor q) => math.pow(q.x - p.x, 2) + math.pow(q.y - p.y, 2).toDouble();
    final candidates = [closest(g.red, g.green), closest(g.green, g.blue), closest(g.blue, g.red)];
    candidates.sort((a, b) => dist(a).compareTo(dist(b)));
    return candidates.first;
  }
}
