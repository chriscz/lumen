// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/domain/power_on.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';

void main() {
  PowerOnBehavior decode(List<int> bytes) => HueBleCodec.decodePowerOn(Uint8List.fromList(bytes));

  group('startup behaviour 932c32bd-1005 (spec 5.2)', () {
    test('knows the characteristic', () {
      expect(HueGatt.startup, '932c32bd-1005-47a2-835a-a8d455b859dd');
    });

    test('last state restores everything with the previous sentinels', () {
      expect(HueBleCodec.encodePowerOn(PowerOnBehavior.lastState(LightKind.color)), [
        0x01, 0x01, 0xFF, // power: previous
        0x02, 0x01, 0xFF, // brightness: previous
        0x03, 0x02, 0xFF, 0xFF, // colour temperature: previous
        0x04, 0x04, 0xFF, 0xFF, 0xFF, 0xFF, // xy: previous
      ]);
    });

    test('only the records the light kind has are written', () {
      expect(HueBleCodec.encodePowerOn(PowerOnBehavior.lastState(LightKind.onOff)), [0x01, 0x01, 0xFF]);
      expect(HueBleCodec.encodePowerOn(PowerOnBehavior.lastState(LightKind.white)), [
        0x01,
        0x01,
        0xFF,
        0x02,
        0x01,
        0xFF,
      ]);
      expect(HueBleCodec.encodePowerOn(PowerOnBehavior.alwaysOff(LightKind.ambiance)), [
        0x01, 0x01, 0x00, 0x02, 0x01, 0xFF, 0x03, 0x02, 0xFF, 0xFF, //
      ]);
    });

    test('a behaviour without a power field writes no power record', () {
      expect(HueBleCodec.encodePowerOn(const PowerOnBehavior(previousBrightness: true)), [0x02, 0x01, 0xFF]);
      expect(HueBleCodec.encodePowerOn(const PowerOnBehavior()), isEmpty);
    });

    test('always on writes the explicit brightness and colour as the control records do', () {
      final white = PowerOnBehavior.alwaysOn(
        LightKind.ambiance,
        const LightState(brightness: 200, color: WhiteColor(366)),
      );
      expect(HueBleCodec.encodePowerOn(white), [0x01, 0x01, 0x01, 0x02, 0x01, 200, 0x03, 0x02, 0x6E, 0x01]);
      final colour = PowerOnBehavior.alwaysOn(
        LightKind.color,
        const LightState(brightness: 254, color: XyColor(0.5, 0.25)),
      );
      expect(HueBleCodec.encodePowerOn(colour), [
        0x01,
        0x01,
        0x01,
        0x02,
        0x01,
        254,
        0x04,
        0x04,
        0x00,
        0x80,
        0x00,
        0x40,
      ]);
    });

    test('always on for a colour the light cannot show keeps the previous colour', () {
      final dimmable = PowerOnBehavior.alwaysOn(
        LightKind.white,
        const LightState(brightness: 10, color: XyColor(0.5, 0.25)),
      );
      expect(HueBleCodec.encodePowerOn(dimmable), [0x01, 0x01, 0x01, 0x02, 0x01, 10]);
      final unknown = PowerOnBehavior.alwaysOn(LightKind.color, const LightState(brightness: 10));
      expect(HueBleCodec.encodePowerOn(unknown), [
        0x01, 0x01, 0x01, 0x02, 0x01, 10, 0x03, 0x02, 0xFF, 0xFF, 0x04, 0x04, 0xFF, 0xFF, 0xFF, 0xFF, //
      ]);
    });

    test('decodes the sentinels back to previous', () {
      final b = decode([
        0x01,
        0x01,
        0xFF,
        0x02,
        0x01,
        0xFF,
        0x03,
        0x02,
        0xFF,
        0xFF,
        0x04,
        0x04,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
      ]);
      expect(b.power, PowerOnPower.previous);
      expect(b.previousBrightness, isTrue);
      expect(b.previousMireds, isTrue);
      expect(b.previousXy, isTrue);
      expect(b.mode, PowerOnMode.lastState);
    });

    test('power on with the previous colour and brightness also reads as last state', () {
      expect(decode([0x01, 0x01, 0x01, 0x02, 0x01, 0xFF, 0x03, 0x02, 0xFF, 0xFF]).mode, PowerOnMode.lastState);
    });

    test('decodes explicit values', () {
      final b = decode([0x01, 0x01, 0x01, 0x02, 0x01, 0x80, 0x04, 0x04, 0x00, 0x80, 0x00, 0x40]);
      expect(b.mode, PowerOnMode.alwaysOn);
      expect(b.brightness, 0x80);
      expect(b.xy, const XyColor(0.5, 0.25));
      expect(decode([0x01, 0x01, 0x00]).mode, PowerOnMode.alwaysOff);
    });

    test('a record without power, or with odd values, is custom', () {
      expect(decode([0x02, 0x01, 0x80]).mode, PowerOnMode.custom);
      expect(decode([]).mode, PowerOnMode.custom);
      expect(decode([0x01, 0x01, 0x07]).mode, PowerOnMode.custom);
    });

    test('round trips every mode', () {
      const state = LightState(brightness: 100, color: WhiteColor(250));
      for (final mode in [PowerOnMode.lastState, PowerOnMode.alwaysOn, PowerOnMode.alwaysOff]) {
        final bytes = HueBleCodec.encodePowerOn(PowerOnBehavior.forMode(mode, LightKind.color, state));
        expect(HueBleCodec.decodePowerOn(bytes).mode, mode);
      }
    });

    test('power on with no look records is always on, as an on/off light writes it', () {
      expect(decode([0x01, 0x01, 0x01]).mode, PowerOnMode.alwaysOn);
      expect(HueBleCodec.encodePowerOn(PowerOnBehavior.alwaysOn(LightKind.onOff, LightState.unknown)), [
        0x01,
        0x01,
        0x01,
      ]);
    });

    test('power on with an explicit brightness and a previous colour is always on', () {
      expect(decode([0x01, 0x01, 0x01, 0x02, 0x01, 10, 0x03, 0x02, 0xFF, 0xFF]).mode, PowerOnMode.alwaysOn);
    });

    test('power previous is last state, power previous with explicit values is custom', () {
      expect(decode([0x01, 0x01, 0xFF]).mode, PowerOnMode.lastState);
      expect(decode([0x01, 0x01, 0xFF, 0x02, 0x01, 0x80]).mode, PowerOnMode.custom);
    });

    test('round trips every mode for every kind of light', () {
      const states = [
        LightState.unknown,
        LightState(brightness: 1),
        LightState(brightness: 100, color: WhiteColor(250)),
        LightState(brightness: 254, color: XyColor(0.5, 0.25)),
      ];
      for (final kind in LightKind.values) {
        for (final state in states) {
          for (final mode in [PowerOnMode.lastState, PowerOnMode.alwaysOn, PowerOnMode.alwaysOff]) {
            final bytes = HueBleCodec.encodePowerOn(PowerOnBehavior.forMode(mode, kind, state));
            expect(HueBleCodec.decodePowerOn(bytes).mode, mode, reason: '$kind $mode $state: $bytes');
          }
        }
      }
    });
  });
}
