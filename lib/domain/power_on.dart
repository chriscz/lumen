// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import '../color/color_math.dart';
import 'light.dart';

/// What a light does when its power returns, as the user picks it.
enum PowerOnMode {
  /// Restore the state the light had before the power went.
  lastState,

  /// Switch on at a fixed brightness and colour.
  alwaysOn,

  /// Stay off.
  alwaysOff,

  /// A combination another app set that none of the above describes.
  custom,
}

/// The power field of a startup record.
enum PowerOnPower { off, on, previous }

/// The startup characteristic `932c32bd-1005` (see docs/protocol.md):
/// each field is an explicit value or "previous", the value the light had
/// before the power was lost. A field that is absent is not in the record.
class PowerOnBehavior {
  const PowerOnBehavior({
    this.power,
    this.brightness,
    this.previousBrightness = false,
    this.mireds,
    this.previousMireds = false,
    this.xy,
    this.previousXy = false,
  });

  final PowerOnPower? power;
  final int? brightness;
  final bool previousBrightness;
  final int? mireds;
  final bool previousMireds;
  final XyColor? xy;
  final bool previousXy;

  bool get _explicitLook => brightness != null || mireds != null || xy != null;

  bool get _previousLook => previousBrightness || previousMireds || previousXy;

  PowerOnMode get mode => switch (power) {
    PowerOnPower.off => PowerOnMode.alwaysOff,
    // An explicit look, or none at all as an on/off light writes it.
    PowerOnPower.on when _explicitLook || !_previousLook => PowerOnMode.alwaysOn,
    // The spec describes "power on, previous colour and brightness" as the
    // last-state policy too, so it reads back as Last state.
    PowerOnPower.on => PowerOnMode.lastState,
    PowerOnPower.previous when !_explicitLook => PowerOnMode.lastState,
    _ => PowerOnMode.custom,
  };

  /// Everything restored as it was, power included.
  factory PowerOnBehavior.lastState(LightKind kind) => PowerOnBehavior(
    power: PowerOnPower.previous,
    previousBrightness: kind.hasBrightness,
    previousMireds: kind.hasTemperature,
    previousXy: kind.hasColor,
  );

  /// Stays off; brightness and colour are kept for the next switch on.
  factory PowerOnBehavior.alwaysOff(LightKind kind) => PowerOnBehavior(
    power: PowerOnPower.off,
    previousBrightness: kind.hasBrightness,
    previousMireds: kind.hasTemperature,
    previousXy: kind.hasColor,
  );

  /// Switches on at [state]'s brightness and colour, as far as [kind] can
  /// show them. A colour the light cannot show is left as it was.
  factory PowerOnBehavior.alwaysOn(LightKind kind, LightState state) {
    final (adapted, _) = ColorMath.adapt(LightState(on: true, color: state.color), kind);
    final color = adapted.color;
    return PowerOnBehavior(
      power: PowerOnPower.on,
      brightness: kind.hasBrightness ? HueRange.brightness(state.brightness ?? HueRange.maxBrightness) : null,
      mireds: color is WhiteColor && kind.hasTemperature ? color.mireds : null,
      previousMireds: kind.hasTemperature && color is! WhiteColor && color is! XyColor,
      xy: color is XyColor && kind.hasColor ? color : null,
      previousXy: kind.hasColor && color is! WhiteColor && color is! XyColor,
    );
  }

  static PowerOnBehavior forMode(PowerOnMode mode, LightKind kind, LightState state) => switch (mode) {
    PowerOnMode.lastState || PowerOnMode.custom => PowerOnBehavior.lastState(kind),
    PowerOnMode.alwaysOn => PowerOnBehavior.alwaysOn(kind, state),
    PowerOnMode.alwaysOff => PowerOnBehavior.alwaysOff(kind),
  };

  @override
  String toString() =>
      'PowerOnBehavior(${mode.name}: power ${power?.name}, bri ${previousBrightness ? 'previous' : brightness}, '
      'mireds ${previousMireds ? 'previous' : mireds}, xy ${previousXy ? 'previous' : xy})';
}
