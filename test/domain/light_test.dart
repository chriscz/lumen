// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/capabilities.dart';
import 'package:lumen/domain/light.dart';

void main() {
  const red = XyColor(0.68, 0.31);
  const candle = LightState(
    on: true,
    brightness: 200,
    color: WhiteColor(366),
    effect: HueEffect.candle,
    effectSpeed: 90,
  );

  group('LightState.apply', () {
    test('a colour without an effect ends the running effect, as the bulb does', () {
      final next = candle.apply(const LightCommand(on: true, color: red));
      expect(next.color, red);
      expect(next.effect, HueEffect.none);
    });

    test('a colour sent with an effect keeps that effect', () {
      final next = candle.apply(const LightCommand(color: red, effect: HueEffect.prism));
      expect(next.effect, HueEffect.prism);
    });

    test('a brightness or power change keeps the running effect', () {
      expect(candle.apply(const LightCommand(brightness: 10)).effect, HueEffect.candle);
      expect(candle.apply(const LightCommand(on: false)).effect, HueEffect.candle);
    });
  });

  test('commands with the same fields are equal and hash alike', () {
    const a = LightCommand(on: true, brightness: 100, color: WhiteColor(300), transition: Duration(seconds: 1));
    const b = LightCommand(on: true, brightness: 100, color: WhiteColor(300), transition: Duration(seconds: 1));
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(const LightCommand(on: true, brightness: 100, color: WhiteColor(300))));
    expect(const LightCommand(effect: HueEffect.candle), isNot(const LightCommand(effect: HueEffect.prism)));
    expect(
      const LightCommand(effect: HueEffect.candle, effectSpeed: 1),
      isNot(const LightCommand(effect: HueEffect.candle)),
    );
    const g = LightGradient([XyColor(0.1, 0.2), XyColor(0.3, 0.4)]);
    expect(const LightCommand(gradient: g), const LightCommand(gradient: g));
    expect(const LightCommand(gradient: g), isNot(const LightCommand(on: false)));
  });

  group('LightCommand.merge', () {
    const startCandle = LightCommand(
      on: true,
      brightness: 200,
      color: WhiteColor(366),
      effect: HueEffect.candle,
      effectSpeed: 90,
    );

    test('a later colour drops an earlier pending effect and its speed', () {
      final merged = startCandle.merge(const LightCommand(on: true, color: red));
      expect(merged.color, red);
      expect(merged.effect, isNull);
      expect(merged.effectSpeed, isNull);
    });

    test('a later effect with its colour stays as sent', () {
      final merged = const LightCommand(color: red).merge(startCandle);
      expect(merged.effect, HueEffect.candle);
      expect(merged.effectSpeed, 90);
      expect(merged.color, const WhiteColor(366));
    });

    test('a later brightness keeps the pending effect', () {
      final merged = startCandle.merge(const LightCommand(brightness: 50));
      expect(merged.effect, HueEffect.candle);
      expect(merged.effectSpeed, 90);
    });
  });

  group('LightGradient', () {
    const blue = XyColor(0.15, 0.06);
    const sunset = LightGradient([red, blue], mode: GradientMode.mirrored, window: (0.1, 0.9), angle: 1.5);

    test('copyWith replaces colours or mode and keeps the window and angle', () {
      final segmented = sunset.copyWith(mode: GradientMode.segmented);
      expect(segmented.mode, GradientMode.segmented);
      expect(segmented.colors, [red, blue]);
      expect(segmented.window, (0.1, 0.9));
      expect(segmented.angle, 1.5);
      final reversed = sunset.copyWith(colors: [blue, red]);
      expect(reversed.colors, [blue, red]);
      expect(reversed.mode, GradientMode.mirrored);
    });

    test('round trips its colours and mode through json', () {
      const plain = LightGradient([red, blue], mode: GradientMode.random);
      expect(LightGradient.fromJson(plain.toJson()), plain);
    });

    test('json without colours, or with only white points, is no gradient', () {
      expect(LightGradient.fromJson('not a map'), isNull);
      expect(LightGradient.fromJson({'mode': 'random'}), isNull);
      expect(
        LightGradient.fromJson({
          'colors': [
            {'mireds': 366},
          ],
        }),
        isNull,
      );
    });

    test('json drops white points and falls back to interpolated for an unknown mode', () {
      final gradient = LightGradient.fromJson({
        'colors': [
          red.toJson(),
          {'mireds': 366},
          blue.toJson(),
        ],
        'mode': 'sparkle',
      });
      expect(gradient, const LightGradient([red, blue]));
    });

    test('equality compares colours in order, mode, window and angle', () {
      const same = LightGradient([red, blue], mode: GradientMode.mirrored, window: (0.1, 0.9), angle: 1.5);
      expect(sunset, same);
      expect(sunset.hashCode, same.hashCode);
      expect(sunset, isNot(sunset.copyWith(colors: [blue, red])));
      expect(sunset, isNot(sunset.copyWith(colors: [red])));
      expect(sunset, isNot(sunset.copyWith(mode: GradientMode.interpolated)));
      expect(sunset, isNot(const LightGradient([red, blue], mode: GradientMode.mirrored, angle: 1.5)));
      expect(sunset, isNot(const LightGradient([red, blue], mode: GradientMode.mirrored, window: (0.1, 0.9))));
    });

    test('describes itself by mode and colours', () {
      expect(sunset.toString(), 'LightGradient(mirrored, [XyColor(0.6800, 0.3100), XyColor(0.1500, 0.0600)])');
    });
  });

  test('a light describes itself by id, name and state', () {
    const light = Light(id: 'l1', name: 'Desk', transport: Transport.ble, address: 'AA', state: candle);
    expect(light.toString(), 'Light(l1, Desk, $candle)');
  });

  test('a bridge light knows its bridge and its id there; a Bluetooth light has neither', () {
    const lamp = Light(id: 'bridge:b1:3', name: 'Lamp', transport: Transport.bridge, address: 'b1/3');
    expect(lamp.bridgeId, 'b1');
    expect(lamp.bridgeLightId, '3');
    const bulb = Light(id: 'ble:AA', name: 'Bulb', transport: Transport.ble, address: 'AA');
    expect(bulb.bridgeId, isNull);
    expect(bulb.bridgeLightId, isNull);
  });

  test('a bridge light offers no effects or gradients', () {
    const lamp = Light(id: 'bridge:b1:3', name: 'Lamp', transport: Transport.bridge, address: 'b1/3');
    expect(lamp.effects, isEmpty);
    expect(lamp.supportsGradient, isFalse);
  });
}
