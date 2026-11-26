// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/capabilities.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';

void main() {
  group('12-bit colour packing (spec 4.1, record 0x07)', () {
    test('scales against the reference primaries and packs little endian across 3 bytes', () {
      // x12 = round(0.3 / 0.7347 x 4095) = 1672 (0x688), y12 = round(0.2 / 0.8431 x 4095) = 971 (0x3CB).
      expect(HueBleCodec.packXy12(const XyColor(0.3, 0.2)), [0x88, 0xB6, 0x3C]);
      expect(HueBleCodec.packXy12(const XyColor(0.7347, 0.8431)), [0xFF, 0xFF, 0xFF]);
      expect(HueBleCodec.packXy12(const XyColor(0, 0)), [0x00, 0x00, 0x00]);
    });

    test('clamps coordinates outside the reference triangle', () {
      expect(HueBleCodec.packXy12(const XyColor(0.9, 1.2)), [0xFF, 0xFF, 0xFF]);
      expect(HueBleCodec.packXy12(const XyColor(-0.1, 0.2)), [0x00, 0xB0, 0x3C]);
    });

    test('unpacks back within the 12-bit step', () {
      final xy = HueBleCodec.unpackXy12(Uint8List.fromList([0x88, 0xB6, 0x3C]));
      expect(xy.x, closeTo(0.3, 0.7347 / 4095));
      expect(xy.y, closeTo(0.2, 0.8431 / 4095));
    });

    test('round trips colours across the gamut within tolerance', () {
      for (final c in const [
        XyColor(0.675, 0.322),
        XyColor(0.1532, 0.0475),
        XyColor(0.17, 0.7),
        XyColor(0.3127, 0.329),
      ]) {
        final back = HueBleCodec.unpackXy12(HueBleCodec.packXy12(c));
        expect(back.x, closeTo(c.x, 0.0001 + 0.7347 / 4095 / 2), reason: '$c');
        expect(back.y, closeTo(c.y, 0.0001 + 0.8431 / 4095 / 2), reason: '$c');
      }
    });
  });

  group('gradient records', () {
    test('the palette starts with a 4-byte header: count in the high nibble, mode doubled', () {
      final bytes = HueBleCodec.encodeControl(
        const LightCommand(
          on: true,
          gradient: LightGradient([
            XyColor(0.3, 0.2),
            XyColor(0.675, 0.322),
            XyColor(0.1532, 0.0475),
          ], mode: GradientMode.mirrored),
        ),
      );
      expect(bytes, [
        0x01, 0x01, 0x01, //
        0x07, 13, 0x30, 0x04, 0x00, 0x00, 0x88, 0xB6, 0x3C, 0xB2, 0xCE, 0x61, 0x56, 0x73, 0x0E,
      ]);
    });

    test('each mode is its index doubled', () {
      for (final mode in GradientMode.values) {
        final bytes = HueBleCodec.encodeControl(
          LightCommand(gradient: LightGradient(const [XyColor(0, 0), XyColor(0, 0)], mode: mode)),
        );
        expect(bytes[3], mode.index * 2);
      }
    });

    test('the window is two eighths and the angle a byte of a turn', () {
      final bytes = HueBleCodec.encodeControl(
        const LightCommand(
          gradient: LightGradient([XyColor(0, 0), XyColor(0, 0)], window: (0.25, 1.0), angle: math.pi),
        ),
      );
      expect(bytes.sublist(bytes.length - 7), [0x09, 0x02, 2, 8, 0x0B, 0x01, 0x80]);
      final full = HueBleCodec.encodeControl(
        const LightCommand(gradient: LightGradient([XyColor(0, 0), XyColor(0, 0)], angle: 2 * math.pi)),
      );
      expect(full.sublist(full.length - 3), [0x0B, 0x01, 0x00], reason: 'masked to a byte');
    });

    test('decodes a palette, window and angle from a report', () {
      final state = HueBleCodec.decodeControl(
        Uint8List.fromList([
          0x01, 0x01, 0x01, //
          0x07, 10, 0x20, 0x06, 0x00, 0x00, 0x88, 0xB6, 0x3C, 0xFF, 0xFF, 0xFF,
          0x09, 0x02, 0, 4,
          0x0B, 0x01, 0x40,
        ]),
      );
      final g = state.gradient!;
      expect(g.mode, GradientMode.segmented);
      expect(g.colors, hasLength(2));
      expect(g.colors[0].x, closeTo(0.3, 0.0002));
      expect(g.colors[1], const XyColor(0.7347, 0.8431));
      expect(g.window, (0.0, 0.5));
      expect(g.angle, closeTo(math.pi / 2, 1e-9));
    });

    test('takes no more points than the bytes hold, and tolerates a stream marker', () {
      final state = HueBleCodec.decodeControl(
        Uint8List.fromList([0x0A, 0x00, 0x07, 7, 0x50, 0x00, 0x00, 0x00, 0x88, 0xB6, 0x3C]),
      );
      expect(state.gradient!.colors, hasLength(1));
      expect(state.gradient!.mode, GradientMode.interpolated);
    });

    test('a palette shorter than its header is ignored', () {
      expect(HueBleCodec.decodeControl(Uint8List.fromList([0x07, 0x02, 0x20, 0x00])).gradient, isNull);
    });
  });
}
