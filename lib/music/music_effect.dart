// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import '../color/color_math.dart';
import '../domain/light.dart';
import 'music_settings.dart';

/// Turns beats and loudness into light commands, for one style. On/off
/// lights are left alone: switching them on every beat would only click.
class MusicEffect {
  MusicEffect(this.settings);

  final MusicSettings settings;

  /// Beats per colour change in [MusicStyle.pulse].
  static const beatsPerBar = 4;

  static const _step = Duration(milliseconds: 100);
  static const _glow = Duration(milliseconds: 200);

  /// The commands for beat number [index], or null when the style has no
  /// beats.
  Map<String, LightCommand>? beat(List<Light> lights, {required int index, required Duration period}) {
    final hues = settings.palette.hues;
    switch (settings.style) {
      case MusicStyle.glow:
        return null;
      case MusicStyle.pulse:
        final bar = index ~/ beatsPerBar;
        final newBar = index % beatsPerBar == 0;
        return {
          for (final (i, l) in _dimmable(lights))
            l.id: LightCommand(
              on: true,
              brightness: HueRange.maxBrightness,
              color: newBar && l.kind.hasColor ? _colour(hues[(bar + i) % hues.length]) : null,
              transition: Duration.zero,
            ),
        };
      case MusicStyle.colours:
        final brightness = (HueRange.maxBrightness * (0.6 + 0.4 * settings.strength)).round();
        return {
          for (final (i, l) in _dimmable(lights))
            l.id: LightCommand(
              on: true,
              brightness: l.kind.hasColor ? brightness : (index.isEven ? HueRange.maxBrightness : _low),
              color: l.kind.hasColor ? _colour(hues[(index + i) % hues.length]) : null,
              transition: _step,
            ),
        };
    }
  }

  /// The commands that follow a beat's peak: a pulse falls away through
  /// most of the beat. Empty for the other styles.
  Map<String, LightCommand> fall(List<Light> lights, {required Duration period}) {
    if (settings.style != MusicStyle.pulse) return const {};
    final over = _round(period * 0.6);
    return {
      for (final (_, l) in _dimmable(lights)) l.id: LightCommand(brightness: _low, transition: over),
    };
  }

  /// The commands for the loudness [level] and [bass], both 0 to 1, in
  /// [MusicStyle.glow]. Empty for the beat styles.
  Map<String, LightCommand> level(List<Light> lights, {required double level, required double bass}) {
    if (settings.style != MusicStyle.glow) return const {};
    final hues = settings.palette.hues;
    final low = _low;
    final brightness = (low + (HueRange.maxBrightness - low) * level.clamp(0.0, 1.0)).round();
    final hue = hues[(bass.clamp(0.0, 1.0) * (hues.length - 1)).round()];
    return {
      for (final (_, l) in _dimmable(lights))
        l.id: LightCommand(
          on: true,
          brightness: HueRange.brightness(brightness),
          color: l.kind.hasColor ? _colour(hue) : null,
          transition: _glow,
        ),
    };
  }

  /// One point of a breath: [amount] from 0, the resting brightness, to 1,
  /// halfway from there to full, reached over [over]. Colours stay. Empty
  /// for Glow.
  Map<String, LightCommand> breathe(List<Light> lights, {required double amount, required Duration over}) {
    if (settings.style == MusicStyle.glow) return const {};
    final low = _low;
    final top = (low + HueRange.maxBrightness) / 2;
    final brightness = HueRange.brightness((low + (top - low) * amount.clamp(0.0, 1.0)).round());
    return {
      for (final (_, l) in _dimmable(lights))
        l.id: LightCommand(on: true, brightness: brightness, transition: _round(over)),
    };
  }

  /// A fade to the resting brightness, for silence. Empty for Glow.
  Map<String, LightCommand> rest(List<Light> lights) {
    if (settings.style == MusicStyle.glow) return const {};
    return {for (final (_, l) in _dimmable(lights)) l.id: LightCommand(brightness: _low, transition: _rest)};
  }

  static const _rest = Duration(seconds: 1);

  /// The brightness a pulse falls to: near off at full strength, most of
  /// the way up when gentle.
  int get _low => HueRange.brightness((10 + 220 * (1 - settings.strength)).round());

  static Iterable<(int, Light)> _dimmable(List<Light> lights) => lights.where((l) => l.kind.hasBrightness).indexed;

  static XyColor _colour(double hue) => ColorMath.hueSatToXy(hue, 1);

  /// Transitions go out in tenths of a second.
  static Duration _round(Duration d) => Duration(milliseconds: (d.inMilliseconds / 100).round() * 100);
}
