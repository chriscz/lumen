// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/capabilities.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';

void main() {
  LightCapabilities decode(List<int> bytes) => HueBleCodec.decodeCapabilities(Uint8List.fromList(bytes));

  group('capabilities 932c32bd-0001 (spec 5.1)', () {
    test('knows the characteristic', () {
      expect(HueGatt.capabilities, '932c32bd-0001-47a2-835a-a8d455b859dd');
    });

    test('light type 1, 2 and 3 are dimmable, white ambiance and colour', () {
      expect(decode([0x00, 0x01, 0x01]).kind, LightKind.white);
      expect(decode([0x00, 0x01, 0x02]).kind, LightKind.ambiance);
      expect(decode([0x00, 0x01, 0x03]).kind, LightKind.color);
    });

    test('a missing light type record means an on/off light', () {
      expect(decode([0x03, 0x01, 0x00]).kind, LightKind.onOff);
      expect(decode([]).kind, LightKind.onOff);
    });

    test('an unknown light type gives no kind, so the caller can fall back', () {
      expect(decode([0x00, 0x01, 0x07]).kind, isNull);
    });

    test('reads the colour temperature range in mireds, little endian', () {
      final caps = decode([0x00, 0x01, 0x02, 0x01, 0x02, 0x99, 0x00, 0x02, 0x02, 0xC6, 0x01]);
      expect(caps.minMireds, 153);
      expect(caps.maxMireds, 454);
    });

    test('a range bound of 0x0000 or 0xFFFF is unset', () {
      final caps = decode([0x01, 0x02, 0x00, 0x00, 0x02, 0x02, 0xFF, 0xFF]);
      expect(caps.minMireds, isNull);
      expect(caps.maxMireds, isNull);
    });

    test('reads the feature flags from bit 1 upwards', () {
      final caps = decode([0x03, 0x01, 0x1E]);
      expect(caps.dynamicScenes, isTrue);
      expect(caps.dynamicEffects, isTrue);
      expect(caps.gradient, isTrue);
      expect(caps.contentRotation, isTrue);
      final none = decode([0x03, 0x01, 0x01]);
      expect(none.dynamicScenes || none.dynamicEffects || none.gradient || none.contentRotation, isFalse);
    });

    test('the effect bitmask uses the wire effect ids, low byte first', () {
      // Bits 1 (candle), 2 (fireplace) and 16 (sunbeam).
      final caps = decode([0x03, 0x01, 0x04, 0x04, 0x03, 0x06, 0x00, 0x01]);
      expect(caps.effects, {HueEffect.candle, HueEffect.fireplace, HueEffect.sunbeam});
    });

    test('without an effect bitmask, the effects flag means every effect', () {
      expect(decode([0x03, 0x01, 0x04]).effects, HueEffect.values.where((e) => e != HueEffect.none).toSet());
      expect(decode([0x03, 0x01, 0x00]).effects, isEmpty);
    });

    test('reads the supported gradient modes and the gradient configuration', () {
      final caps = decode([0x03, 0x01, 0x08, 0x08, 0x01, 0x05, 0x05, 0x01, 0x02]);
      expect(caps.gradientModes, {GradientMode.interpolated, GradientMode.mirrored});
      expect(caps.gradientOrientation, isFalse);
      expect(caps.gradientOrder, isTrue);
    });

    test('skips unknown records and a truncated tail', () {
      final caps = decode([0x0E, 0x02, 0xAA, 0xBB, 0x00, 0x01, 0x03, 0x01, 0x02, 0x99]);
      expect(caps.kind, LightKind.color);
      expect(caps.minMireds, isNull);
    });

    test('survives a JSON round trip', () {
      final caps = decode([
        0x00,
        0x01,
        0x03,
        0x01,
        0x02,
        0x99,
        0x00,
        0x03,
        0x01,
        0x0C,
        0x04,
        0x01,
        0x02,
        0x08,
        0x01,
        0x05,
      ]);
      final back = LightCapabilities.fromJson(jsonDecode(jsonEncode(caps.toJson())) as Map<String, Object?>);
      expect(back, caps);
      expect(back.effects, {HueEffect.candle});
      expect(back.gradientModes, {GradientMode.interpolated, GradientMode.mirrored});
    });
  });
}
