import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';

void main() {
  group('control TLV encoding', () {
    test('encodes power on', () {
      expect(HueBleCodec.encodeControl(const LightCommand(on: true)), Uint8List.fromList([0x01, 0x01, 0x01]));
    });

    // Per BLE GATT wire format (docs/protocol.md): xy is round(coord x 65536),
    // rather than floor(coord x 0xFFFF), so 0.5 is 0x8000 rather than 0x7FFF.
    test('encodes power, brightness and xy colour in one write', () {
      final bytes = HueBleCodec.encodeControl(const LightCommand(on: true, brightness: 200, color: XyColor(0.5, 0.25)));
      // x = round(0.5 * 65536) = 32768 (0x8000), y = round(0.25 * 65536) = 16384 (0x4000).
      expect(bytes, [0x01, 0x01, 0x01, 0x02, 0x01, 200, 0x04, 0x04, 0x00, 0x80, 0x00, 0x40]);
    });

    test('clamps each xy coordinate to 1..65279', () {
      expect(HueBleCodec.encodeControl(const LightCommand(color: XyColor(0, 1))), [0x04, 0x04, 1, 0, 0xFF, 0xFE]);
      expect(HueBleCodec.encodeXy(const XyColor(0.3, 0.3)), [0xCD, 0x4C, 0xCD, 0x4C]);
    });

    test('brightness is round(level x 253) + 1 for a level of 0 to 1', () {
      expect(HueBleCodec.brightnessWire(0), 1);
      expect(HueBleCodec.brightnessWire(1), 254);
      expect(HueBleCodec.brightnessWire(0.5), 128);
      expect(HueBleCodec.brightnessWire(2), 254);
      expect(HueBleCodec.brightnessLevel(1), 0);
      expect(HueBleCodec.brightnessLevel(254), 1);
      expect(HueBleCodec.brightnessLevel(128), closeTo(0.5, 0.002));
    });

    test('encodes colour temperature in mireds, little endian', () {
      final bytes = HueBleCodec.encodeControl(const LightCommand(color: WhiteColor(366)));
      expect(bytes, [0x03, 0x02, 0x6E, 0x01]);
    });

    // Per BLE GATT wire format (docs/protocol.md): the wire clamps mireds to
    // 1..65279. The per-light range from the capabilities is the controller's
    // job, so the codec does not clamp to 153..500.
    test('clamps brightness to 1..254 and mireds to 1..65279', () {
      expect(HueBleCodec.encodeControl(const LightCommand(brightness: 0)), [0x02, 0x01, 1]);
      expect(HueBleCodec.encodeControl(const LightCommand(brightness: 255)), [0x02, 0x01, 254]);
      expect(HueBleCodec.encodeControl(const LightCommand(color: WhiteColor(100))), [0x03, 0x02, 100, 0]);
      expect(HueBleCodec.encodeControl(const LightCommand(color: WhiteColor(900))), [0x03, 0x02, 0x84, 0x03]);
      expect(HueBleCodec.encodeControl(const LightCommand(color: WhiteColor(0))), [0x03, 0x02, 1, 0]);
      expect(HueBleCodec.encodeControl(const LightCommand(color: WhiteColor(70000))), [0x03, 0x02, 0xFF, 0xFE]);
    });

    test('appends a transition in 100 ms units', () {
      final bytes = HueBleCodec.encodeControl(
        const LightCommand(brightness: 10, transition: Duration(milliseconds: 400)),
      );
      expect(bytes, [0x02, 0x01, 10, 0x05, 0x02, 4, 0]);
    });

    test('encodes an effect and its speed', () {
      final bytes = HueBleCodec.encodeControl(const LightCommand(effect: HueEffect.candle, effectSpeed: 128));
      expect(bytes, [0x06, 0x01, 0x01, 0x08, 0x01, 128]);
    });
  });

  group('control TLV decoding', () {
    test('decodes a white mode report of 10 bytes', () {
      final state = HueBleCodec.decodeControl(
        Uint8List.fromList([0x01, 0x01, 0x01, 0x02, 0x01, 0x80, 0x03, 0x02, 0x6E, 0x01]),
      );
      expect(state.on, isTrue);
      expect(state.brightness, 0x80);
      expect(state.color, const WhiteColor(366));
    });

    test('decodes a colour mode report of 12 bytes', () {
      final state = HueBleCodec.decodeControl(
        Uint8List.fromList([0x01, 0x01, 0x00, 0x02, 0x01, 0x10, 0x04, 0x04, 0xFF, 0x7F, 0xFF, 0x3F]),
      );
      expect(state.on, isFalse);
      expect(state.brightness, 0x10);
      final xy = state.color as XyColor;
      expect(xy.x, closeTo(0.5, 0.0001));
      expect(xy.y, closeTo(0.25, 0.0001));
    });

    test('decodes an effect report and skips unknown records', () {
      final state = HueBleCodec.decodeControl(
        Uint8List.fromList([0x09, 0x02, 0xAA, 0xBB, 0x01, 0x01, 0x01, 0x06, 0x01, 0x02, 0x08, 0x01, 0x40]),
      );
      expect(state.on, isTrue);
      expect(state.effect, HueEffect.fireplace);
      expect(state.effectSpeed, 0x40);
    });

    test('decodes xy as raw / 65536 and still reads values written the old way', () {
      final xy = HueBleCodec.decodeXy(Uint8List.fromList([0x00, 0x80, 0x00, 0x40]))!;
      expect(xy.x, 0.5);
      expect(xy.y, 0.25);
      final old = HueBleCodec.decodeXy(Uint8List.fromList([0xFF, 0x7F, 0xFF, 0x3F]))!;
      expect(old.x, closeTo(0.5, 0.0001));
    });

    test('brightness 0xFF means unset', () {
      expect(HueBleCodec.decodeControl(Uint8List.fromList([0x02, 0x01, 0xFF])).brightness, isNull);
      expect(HueBleCodec.decodeBrightness(Uint8List.fromList([0xFF])), isNull);
      expect(HueBleCodec.decodeBrightness(Uint8List.fromList([0x00])), 1, reason: 'tolerates an old zero');
    });

    test('mireds of 0x0000 or 0xFFFF mean not in white mode', () {
      expect(HueBleCodec.decodeControl(Uint8List.fromList([0x03, 0x02, 0x00, 0x00])).color, isNull);
      expect(HueBleCodec.decodeControl(Uint8List.fromList([0x03, 0x02, 0xFF, 0xFF])).color, isNull);
    });

    test('round trips through encode and decode', () {
      const command = LightCommand(on: true, brightness: 77, color: XyColor(0.3, 0.6));
      final state = HueBleCodec.decodeControl(HueBleCodec.encodeControl(command));
      expect(state.on, isTrue);
      expect(state.brightness, 77);
      expect((state.color as XyColor).x, closeTo(0.3, 0.0001));
    });

    test('stops at a truncated record instead of reading past the end', () {
      final state = HueBleCodec.decodeControl(Uint8List.fromList([0x01, 0x01, 0x01, 0x04, 0x04, 0x00]));
      expect(state.on, isTrue);
      expect(state.color, isNull);
    });
  });

  group('single characteristics', () {
    test('power is one byte', () {
      expect(HueBleCodec.encodePower(true), [1]);
      expect(HueBleCodec.decodePower(Uint8List.fromList([0])), isFalse);
    });

    test('xy reads 0xFFFFFFFF as no colour (white mode)', () {
      expect(HueBleCodec.decodeXy(Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF])), isNull);
    });

    test('mireds read 0xFFFF as no temperature (colour mode)', () {
      expect(HueBleCodec.decodeMireds(Uint8List.fromList([0xFF, 0xFF])), isNull);
      expect(HueBleCodec.decodeMireds(Uint8List.fromList([0x6E, 0x01])), 366);
    });
  });

  group('proximity pairing', () {
    test('reads the flag byte of 97fe6561-2001', () {
      final open = ProximityFlags(0x05);
      expect(open.openForBonding, isTrue);
      expect(open.notCommissioned, isTrue);
      expect(open.bondedToPhone, isFalse);
      final expired = ProximityFlags(0x18);
      expect(expired.windowExpired, isTrue);
      expect(expired.onBridge, isTrue);
      expect(expired.openForBonding, isFalse);
      expect(ProximityFlags(0x02).bondedToPhone, isTrue);
      expect(expired.toString(), contains('0x18'));
      expect(expired.toString(), contains('window expired'));
    });

    test('the third byte of the FE0F service data says whether the bulb is open for bonding', () {
      expect(HueBleCodec.openForBonding(Uint8List.fromList([0x00, 0x00, 0x04])), isTrue);
      expect(HueBleCodec.openForBonding(Uint8List.fromList([0x00, 0x00, 0xF3])), isFalse);
      expect(HueBleCodec.openForBonding(Uint8List.fromList([0x00])), isNull);
      expect(HueBleCodec.openForBonding(null), isNull);
    });

    test('knows the proximity and discoverable characteristics', () {
      expect(HueGatt.proximity, '97fe6561-2001-4f62-86e9-b71ee2da3d22');
      expect(HueGatt.makeDiscoverable, '97fe6561-2004-4f62-86e9-b71ee2da3d22');
    });
  });
}
