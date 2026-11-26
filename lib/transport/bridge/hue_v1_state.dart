// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import '../../domain/light.dart';

/// The light state fields of the Hue Bridge v1 API (`on`, `bri`, `xy`, `ct`,
/// `transitiontime`), shared by the bridge client, the emulator and the
/// simulated bridge. Callers that differ in what they write say so through
/// the named parameters.
abstract final class HueV1State {
  /// The v1 body for [on], [brightness], [color] and [transition]: only the
  /// fields given, brightness clamped, xy rounded to four decimals, and ct
  /// clamped unless [clampCt] is false.
  static Map<String, Object> encode({
    bool? on,
    int? brightness,
    LightColor? color,
    Duration? transition,
    bool clampCt = true,
  }) => {
    'on': ?on,
    if (brightness != null) 'bri': HueRange.brightness(brightness),
    ...colorJson(color, clampCt: clampCt),
    if (transition != null) 'transitiontime': toDeciseconds(transition),
  };

  static Map<String, Object> fromCommand(LightCommand c) =>
      encode(on: c.on, brightness: c.brightness, color: c.color, transition: c.transition);

  /// The `xy` or `ct` key for [color], with `colormode` after it when
  /// [colormode] is set.
  static Map<String, Object> colorJson(
    LightColor? color, {
    bool clampCt = true,
    bool round = true,
    bool colormode = false,
  }) => switch (color) {
    WhiteColor(:final mireds) => {'ct': clampCt ? HueRange.mireds(mireds) : mireds, if (colormode) 'colormode': 'ct'},
    final XyColor xy => {
      'xy': round ? xyJson(xy) : [xy.x, xy.y],
      if (colormode) 'colormode': 'xy',
    },
    null => const {},
  };

  static List<double> xyJson(XyColor xy) => [round4(xy.x), round4(xy.y)];

  static double round4(double v) => (v * 10000).round() / 10000;

  static int toDeciseconds(Duration d) => (d.inMilliseconds / 100).round();

  static Duration fromDeciseconds(num deciseconds) => Duration(milliseconds: deciseconds.round() * 100);

  /// `on`, `bri` and the colour of a v1 state or body.
  static LightState stateOf(
    Map<String, Object?> json, {
    bool honourColormode = true,
    bool acceptXy = true,
    bool acceptCt = true,
  }) => LightState(
    on: json['on'] as bool?,
    brightness: (json['bri'] as num?)?.toInt(),
    color: colorOf(json, honourColormode: honourColormode, acceptXy: acceptXy, acceptCt: acceptCt),
  );

  /// The colour in [json]: xy before ct, except that `colormode: ct` picks
  /// ct when [honourColormode] is set. [acceptXy] and [acceptCt] false skip
  /// that key.
  static LightColor? colorOf(
    Map<String, Object?> json, {
    bool honourColormode = true,
    bool acceptXy = true,
    bool acceptCt = true,
  }) {
    final ctMode = honourColormode && json['colormode'] == 'ct';
    if (acceptXy && !ctMode) {
      if (xyOf(json['xy']) case final xy?) return xy;
    }
    if (acceptCt) {
      if (json['ct'] case final num ct) return WhiteColor(ct.toInt());
    }
    return null;
  }

  static XyColor? xyOf(Object? value) => switch (value) {
    [final num x, final num y] => XyColor(x.toDouble(), y.toDouble()),
    _ => null,
  };
}
