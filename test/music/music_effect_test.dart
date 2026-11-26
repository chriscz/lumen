// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/music/music_effect.dart';
import 'package:lumen/music/music_settings.dart';

void main() {
  Light light(String id, LightKind kind) => Light(
    id: id,
    name: id,
    transport: Transport.ble,
    address: 'AA:$id',
    kind: kind,
    state: const LightState(on: true, brightness: 100),
  );

  final colour = light('c', LightKind.color);
  final colour2 = light('d', LightKind.color);
  final white = light('w', LightKind.white);
  final plug = light('p', LightKind.onOff);
  const period = Duration(milliseconds: 500);

  MusicEffect effect(MusicStyle style, {double strength = 1, MusicPalette palette = MusicPalette.party}) =>
      MusicEffect(MusicSettings(style: style, strength: strength, palette: palette));

  test('a pulse jumps to full brightness at once on the beat, then falls through most of the beat', () {
    final e = effect(MusicStyle.pulse);
    final peak = e.beat([colour, white], index: 0, period: period)!;
    expect(peak['c']!.brightness, 254);
    expect(peak['c']!.transition, Duration.zero);
    expect(peak['c']!.on, isTrue);
    expect(peak['w']!.brightness, 254);
    expect(peak['w']!.color, isNull, reason: 'a white bulb only pulses');
    final fall = e.fall([colour, white], period: period);
    expect(fall['c']!.brightness, lessThan(60));
    expect(fall['c']!.transition, const Duration(milliseconds: 300));
  });

  test('strength sets how deep the pulse falls', () {
    final deep = effect(MusicStyle.pulse, strength: 1).fall([colour], period: period)['c']!.brightness!;
    final soft = effect(MusicStyle.pulse, strength: 0.2).fall([colour], period: period)['c']!.brightness!;
    expect(soft, greaterThan(deep + 100));
  });

  test('a pulse changes colour once a bar, every fourth beat', () {
    final e = effect(MusicStyle.pulse);
    final colours = [for (var i = 0; i < 8; i++) e.beat([colour], index: i, period: period)!['c']!.color];
    expect(colours[0], isNotNull);
    expect(colours.sublist(1, 4), [null, null, null]);
    expect(colours[4], isNotNull);
    expect(colours[4], isNot(colours[0]));
  });

  test('colour steps give each light the next colour of the palette on every beat', () {
    final e = effect(MusicStyle.colours);
    final a = e.beat([colour, colour2], index: 0, period: period)!;
    final b = e.beat([colour, colour2], index: 1, period: period)!;
    expect(a['c']!.color, isNot(a['d']!.color), reason: 'neighbours differ');
    expect(b['c']!.color, a['d']!.color, reason: 'colours move along');
    expect(a['c']!.transition, const Duration(milliseconds: 100));
    expect(e.fall([colour], period: period), isEmpty);
  });

  test('glow ignores beats and follows the loudness', () {
    final e = effect(MusicStyle.glow);
    expect(e.beat([colour], index: 0, period: period), isNull);
    final loud = e.level([colour], level: 1, bass: 1)['c']!;
    final quiet = e.level([colour], level: 0.1, bass: 0.1)['c']!;
    expect(loud.brightness, greaterThan(quiet.brightness! + 100));
    expect(loud.transition, const Duration(milliseconds: 200));
    expect(loud.color, isNot(quiet.color));
  });

  test('beat styles do not follow the loudness', () {
    expect(effect(MusicStyle.pulse).level([colour], level: 1, bass: 1), isEmpty);
  });

  test('on/off lights are left alone, so a plug never flickers', () {
    final e = effect(MusicStyle.pulse);
    expect(e.beat([plug], index: 0, period: period), isEmpty);
    expect(e.fall([plug], period: period), isEmpty);
  });

  test('palettes differ', () {
    final party = effect(MusicStyle.colours).beat([colour], index: 0, period: period)!['c']!.color;
    final warm = effect(
      MusicStyle.colours,
      palette: MusicPalette.warm,
    ).beat([colour], index: 0, period: period)!['c']!.color;
    expect(party, isNot(warm));
  });

  test('a breath runs from the resting brightness to halfway to full, leaving colours alone', () {
    final e = effect(MusicStyle.pulse, strength: 1);
    final rest = e.fall([colour], period: period)['c']!.brightness!;
    final low = e.breathe([colour, white, plug], amount: 0, over: const Duration(milliseconds: 250));
    final top = e.breathe([colour], amount: 1, over: const Duration(milliseconds: 250));
    expect(low['c']!.brightness, rest);
    expect(top['c']!.brightness, ((rest + HueRange.maxBrightness) / 2).round());
    expect(top['c']!.color, isNull);
    expect(low.containsKey('p'), isFalse);
    expect(low['c']!.transition, const Duration(milliseconds: 300), reason: 'rounded to tenths');
  });

  test('resting fades the beat styles to the resting brightness, and glow neither breathes nor rests', () {
    final e = effect(MusicStyle.colours, strength: 0.5);
    expect(e.rest([colour])['c']!.transition, const Duration(seconds: 1));
    expect(effect(MusicStyle.glow).rest([colour]), isEmpty);
    expect(effect(MusicStyle.glow).breathe([colour], amount: 1, over: const Duration(milliseconds: 250)), isEmpty);
  });
}
