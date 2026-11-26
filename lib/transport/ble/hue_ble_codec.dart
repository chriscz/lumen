// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../domain/capabilities.dart';
import '../../domain/light.dart';
import '../../domain/power_on.dart';

/// GATT identifiers of Hue Bluetooth bulbs. See
/// docs/protocol.md.
abstract final class HueGatt {
  /// Advertised by every Hue Bluetooth bulb; used as the scan filter.
  static const advertisedService = '0000fe0f-0000-1000-8000-00805f9b34fb';

  static const lightService = '932c32bd-0000-47a2-835a-a8d455b859dd';
  static const power = '932c32bd-0002-47a2-835a-a8d455b859dd';
  static const brightness = '932c32bd-0003-47a2-835a-a8d455b859dd';
  static const temperature = '932c32bd-0004-47a2-835a-a8d455b859dd';
  static const xy = '932c32bd-0005-47a2-835a-a8d455b859dd';
  static const control = '932c32bd-0007-47a2-835a-a8d455b859dd';

  /// Identify: write 0x01 with response and the light blinks.
  static const identify = '932c32bd-0006-47a2-835a-a8d455b859dd';

  /// Startup (power-on) behaviour: control records with "previous" sentinels.
  static const startup = '932c32bd-1005-47a2-835a-a8d455b859dd';

  /// User-defined minimum dim level: one byte, scaled as brightness.
  static const minDim = '932c32bd-1006-47a2-835a-a8d455b859dd';

  /// Light type, colour temperature range, effects and gradient support.
  static const capabilities = '932c32bd-0001-47a2-835a-a8d455b859dd';

  static const configService = '0000fe0f-0000-1000-8000-00805f9b34fb';
  static const name = '97fe6561-0003-4f62-86e9-b71ee2da3d22';

  /// Proximity pairing: write 0x01 without response, then read a
  /// [ProximityFlags] byte.
  static const proximity = '97fe6561-2001-4f62-86e9-b71ee2da3d22';

  /// "Make discoverable": write 0x01 with response to open the bulb for
  /// bonding for about five minutes.
  static const makeDiscoverable = '97fe6561-2004-4f62-86e9-b71ee2da3d22';

  /// Key material of the application-layer security (the "DLC key"): a TLV
  /// set whose non-zero entry means a key is provisioned.
  static const securityKey = '97fe6561-2005-4f62-86e9-b71ee2da3d22';

  static const deviceInfoService = '0000180a-0000-1000-8000-00805f9b34fb';
  static const model = '00002a24-0000-1000-8000-00805f9b34fb';
}

/// The flag byte a bulb answers on [HueGatt.proximity].
class ProximityFlags {
  const ProximityFlags(this.raw);

  final int raw;

  bool get openForBonding => raw & 0x01 != 0;
  bool get bondedToPhone => raw & 0x02 != 0;
  bool get notCommissioned => raw & 0x04 != 0;
  bool get windowExpired => raw & 0x08 != 0;
  bool get onBridge => raw & 0x10 != 0;

  @override
  String toString() {
    final names = [
      if (openForBonding) 'open for bonding',
      if (bondedToPhone) 'bonded to this phone',
      if (notCommissioned) 'not commissioned',
      if (windowExpired) 'window expired',
      if (onBridge) 'on a bridge',
    ];
    return '0x${raw.toRadixString(16).padLeft(2, '0')} (${names.isEmpty ? 'none' : names.join(', ')})';
  }
}

/// Encodes and decodes the bytes Hue bulbs use on their characteristics.
abstract final class HueBleCodec {
  /// Whether the FE0F service data of an advertisement says the bulb is
  /// open for bonding (bit 0x04 of the third byte), or null if unknown.
  static bool? openForBonding(List<int>? serviceData) =>
      serviceData == null || serviceData.length < 3 ? null : serviceData[2] & 0x04 != 0;

  static const _tPower = 0x01;
  static const _tBrightness = 0x02;
  static const _tMireds = 0x03;
  static const _tXy = 0x04;
  static const _tTransition = 0x05;
  static const _tEffect = 0x06;
  static const _tEffectSpeed = 0x08;
  static const _tPalette = 0x07;
  static const _tWindow = 0x09;
  static const _tAngle = 0x0B;

  /// One write to the combined control characteristic.
  static Uint8List encodeControl(LightCommand c) {
    final out = BytesBuilder();
    void record(int type, List<int> value) => out
      ..addByte(type)
      ..addByte(value.length)
      ..add(value);

    if (c.on case final on?) record(_tPower, [on ? 1 : 0]);
    if (c.brightness case final b?) record(_tBrightness, [HueRange.brightness(b)]);
    switch (c.color) {
      case WhiteColor(:final mireds):
        record(_tMireds, _u16(_wire16(mireds)));
      case XyColor(:final x, :final y):
        record(_tXy, [..._u16(_scale(x)), ..._u16(_scale(y))]);
      case null:
    }
    // An effect of none is sent as no effect record: setting a colour ends it.
    if (c.gradient case final g?) {
      record(_tPalette, _palette(g));
      if (g.window case (final start, final end)) {
        record(_tWindow, [(start.clamp(0.0, 1.0) * 8).round(), (end.clamp(0.0, 1.0) * 8).round()]);
      }
      if (g.angle case final a?) record(_tAngle, [(a * 256 / (2 * math.pi)).round() & 0xFF]);
    }
    if (c.effect case final e? when e != HueEffect.none) record(_tEffect, [e.id]);
    if (c.effectSpeed case final s?) record(_tEffectSpeed, [s.clamp(0, 255)]);
    if (c.transition case final t?) {
      record(_tTransition, _u16((t.inMilliseconds / 100).round().clamp(0, 0xFFFF)));
    }
    return out.toBytes();
  }

  /// A notification from, or a read of, the combined control characteristic.
  static LightState decodeControl(Uint8List bytes) {
    bool? on;
    int? brightness;
    LightColor? color;
    HueEffect? effect;
    int? effectSpeed;
    List<XyColor>? palette;
    var mode = GradientMode.interpolated;
    (double, double)? window;
    double? angle;
    for (final (type, v) in records(bytes)) {
      switch ((type, v.length)) {
        case (_tPower, 1):
          on = v[0] != 0;
        case (_tBrightness, 1):
          brightness = decodeBrightness(v);
        case (_tMireds, 2):
          final m = decodeMireds(v);
          if (m != null) color = WhiteColor(m);
        case (_tXy, 4):
          color = decodeXy(v) ?? color;
        case (_tEffect, 1):
          effect = HueEffect.fromId(v[0]);
        case (_tEffectSpeed, 1):
          effectSpeed = v[0];
        case (_tPalette, final n) when n >= 4:
          final count = math.min(v[0] >> 4, (n - 4) ~/ 3);
          mode = GradientMode.values.elementAtOrNull(v[1] >> 1) ?? GradientMode.interpolated;
          palette = [for (var i = 0; i < count; i++) unpackXy12(Uint8List.sublistView(v, 4 + 3 * i, 7 + 3 * i))];
        case (_tWindow, 2):
          window = (v[0] / 8, v[1] / 8);
        case (_tAngle, 1):
          angle = v[0] * 2 * math.pi / 256;
      }
    }
    return LightState(
      on: on,
      brightness: brightness,
      color: color,
      effect: effect,
      effectSpeed: effectSpeed,
      gradient: palette == null || palette.isEmpty
          ? null
          : LightGradient(palette, mode: mode, window: window, angle: angle),
    );
  }

  /// The reference primaries the 12-bit palette colours are scaled against.
  static const _xMax = 0.7347;
  static const _yMax = 0.8431;

  /// One palette colour in 3 bytes: x and y as 12-bit fractions of the
  /// reference primaries, packed little endian (low byte of x; high nibble
  /// of x with the low nibble of y; high byte of y).
  static Uint8List packXy12(XyColor c) {
    final x = ((c.x / _xMax).clamp(0.0, 1.0) * 4095).round();
    final y = ((c.y / _yMax).clamp(0.0, 1.0) * 4095).round();
    return Uint8List.fromList([x & 0xFF, (x >> 8 & 0x0F) | (y & 0x0F) << 4, y >> 4 & 0xFF]);
  }

  static XyColor unpackXy12(Uint8List b) {
    final x = b[0] | (b[1] & 0x0F) << 8;
    final y = b[1] >> 4 | b[2] << 4;
    return XyColor(x / 4095 * _xMax, y / 4095 * _yMax);
  }

  /// Record 0x07: a 4-byte header (colour count in the high nibble of the
  /// first byte, the mode index doubled in the second, then two zero bytes)
  /// and 3 bytes per colour.
  static List<int> _palette(LightGradient g) {
    final colors = g.colors.take(15).toList();
    return [colors.length << 4, g.mode.index * 2, 0, 0, for (final c in colors) ...packXy12(c)];
  }

  /// Splits a TLV value into (type, value) records. A truncated last record
  /// is dropped, as the Hue app does.
  static Iterable<(int, Uint8List)> records(Uint8List bytes) sync* {
    var i = 0;
    while (i + 2 <= bytes.length) {
      final type = bytes[i];
      final length = bytes[i + 1];
      final start = i + 2;
      if (start + length > bytes.length) return;
      yield (type, Uint8List.sublistView(bytes, start, start + length));
      i = start + length;
    }
  }

  /// The capabilities characteristic `932c32bd-0001` (see docs/protocol.md).
  static LightCapabilities decodeCapabilities(Uint8List bytes) {
    int? lightType;
    int? minMireds;
    int? maxMireds;
    var flags = 0;
    Set<HueEffect>? effects;
    var modes = <GradientMode>{};
    var config = 0;
    for (final (type, v) in records(bytes)) {
      switch ((type, v.length)) {
        case (0x00, 1):
          lightType = v[0];
        case (0x01, 2):
          minMireds = decodeMireds(v);
        case (0x02, 2):
          maxMireds = decodeMireds(v);
        case (0x03, 1):
          flags = v[0];
        case (0x04, _):
          effects = {
            for (final e in HueEffect.values)
              if (e != HueEffect.none && e.id ~/ 8 < v.length && v[e.id ~/ 8] & (1 << e.id % 8) != 0) e,
          };
        case (0x05, 1):
          config = v[0];
        case (0x08, 1):
          modes = {
            for (final m in GradientMode.values)
              if (v[0] & (1 << m.index) != 0) m,
          };
      }
    }
    final dynamicEffects = flags & 0x04 != 0;
    return LightCapabilities(
      lightType: lightType,
      minMireds: minMireds,
      maxMireds: maxMireds,
      dynamicScenes: flags & 0x02 != 0,
      dynamicEffects: dynamicEffects,
      gradient: flags & 0x08 != 0,
      contentRotation: flags & 0x10 != 0,
      effects: effects ?? (dynamicEffects ? HueEffect.values.where((e) => e != HueEffect.none).toSet() : const {}),
      gradientModes: modes,
      gradientOrientation: config & 0x01 != 0,
      gradientOrder: config & 0x02 != 0,
    );
  }

  /// The startup characteristic `932c32bd-1005` (see docs/protocol.md): the power,
  /// brightness, colour temperature and xy records of the combined control
  /// characteristic, each an explicit value or "previous", which is 0xFF
  /// bytes (0xFFFF for the colour temperature).
  static Uint8List encodePowerOn(PowerOnBehavior b) {
    final out = BytesBuilder();
    void record(int type, List<int> value) => out
      ..addByte(type)
      ..addByte(value.length)
      ..add(value);
    switch (b.power) {
      case PowerOnPower.off:
        record(_tPower, [0x00]);
      case PowerOnPower.on:
        record(_tPower, [0x01]);
      case PowerOnPower.previous:
        record(_tPower, [0xFF]);
      case null:
    }
    if (b.previousBrightness) {
      record(_tBrightness, [0xFF]);
    } else if (b.brightness case final v?) {
      record(_tBrightness, [HueRange.brightness(v)]);
    }
    if (b.previousMireds) {
      record(_tMireds, [0xFF, 0xFF]);
    } else if (b.mireds case final m?) {
      // 65279 is the highest explicit value, so it never reads as previous.
      record(_tMireds, _u16(_wire16(m)));
    }
    if (b.previousXy) {
      record(_tXy, [0xFF, 0xFF, 0xFF, 0xFF]);
    } else if (b.xy case final c?) {
      record(_tXy, encodeXy(c));
    }
    return out.toBytes();
  }

  static PowerOnBehavior decodePowerOn(Uint8List bytes) {
    PowerOnPower? power;
    var unknownPower = false;
    int? brightness;
    var previousBrightness = false;
    int? mireds;
    var previousMireds = false;
    XyColor? xy;
    var previousXy = false;
    for (final (type, v) in records(bytes)) {
      switch ((type, v.length)) {
        case (_tPower, 1):
          power = switch (v[0]) {
            0x00 => PowerOnPower.off,
            0x01 => PowerOnPower.on,
            0xFF => PowerOnPower.previous,
            _ => null,
          };
          unknownPower = power == null;
        case (_tBrightness, 1):
          previousBrightness = v[0] == 0xFF;
          brightness = previousBrightness ? null : HueRange.brightness(v[0]);
        case (_tMireds, 2):
          final raw = v[0] | v[1] << 8;
          previousMireds = raw == 0xFFFF;
          mireds = previousMireds || raw == 0 ? null : raw;
        case (_tXy, 4):
          previousXy = v.every((b) => b == 0xFF);
          xy = previousXy ? null : decodeXy(v);
      }
    }
    return PowerOnBehavior(
      power: unknownPower ? null : power,
      brightness: brightness,
      previousBrightness: previousBrightness,
      mireds: mireds,
      previousMireds: previousMireds,
      xy: xy,
      previousXy: previousXy,
    );
  }

  /// Whether a read of [HueGatt.securityKey] says a key is set. The spec
  /// does not name the entry the Hue app checks, so any entry with a
  /// non-zero byte counts; empty and all-zero entries mean "not set".
  static bool securityKeySet(Uint8List bytes) => records(bytes).any((r) => r.$2.any((b) => b != 0));

  /// The minimum dim level for 932c32bd-1006: a [level] of 0 to 1 as one
  /// byte, round(level x 253) + 1 (see docs/protocol.md).
  static Uint8List encodeMinDim(double level) => Uint8List.fromList([brightnessWire(level)]);

  static double? decodeMinDim(Uint8List bytes) => bytes.isEmpty || bytes[0] == 0xFF ? null : brightnessLevel(bytes[0]);

  /// The most bytes the name characteristic takes.
  static const maxNameBytes = 32;

  /// A name for 97fe6561-0003: UTF-8, cut to [maxNameBytes] between
  /// characters, never inside one.
  static Uint8List encodeName(String name) {
    final out = BytesBuilder();
    for (final rune in name.runes) {
      final bytes = utf8.encode(String.fromCharCode(rune));
      if (out.length + bytes.length > maxNameBytes) break;
      out.add(bytes);
    }
    return out.toBytes();
  }

  static Uint8List encodePower(bool on) => Uint8List.fromList([on ? 1 : 0]);

  static bool decodePower(Uint8List bytes) => bytes.isNotEmpty && bytes[0] != 0;

  static Uint8List encodeBrightness(int b) => Uint8List.fromList([HueRange.brightness(b)]);

  /// The wire byte for a brightness [level] of 0 to 1: round(level x 253) + 1,
  /// so 1 to 254. The app's own brightness scale is this byte.
  static int brightnessWire(double level) => (level.clamp(0.0, 1.0) * 253).round() + 1;

  /// The level of 0 to 1 a brightness wire byte stands for.
  static double brightnessLevel(int wire) => (HueRange.brightness(wire) - 1) / 253;

  /// 0xFF means unset. Older bulbs and earlier versions of this app may send
  /// 0, which is read as the lowest level.
  static int? decodeBrightness(Uint8List bytes) =>
      bytes.isEmpty || bytes[0] == 0xFF ? null : HueRange.brightness(bytes[0]);

  static Uint8List encodeMireds(int mireds) => Uint8List.fromList(_u16(_wire16(mireds)));

  /// 0x0000 and 0xFFFF mean the light is not in colour temperature mode.
  static int? decodeMireds(Uint8List bytes) {
    if (bytes.length < 2) return null;
    final m = bytes[0] | bytes[1] << 8;
    return m == 0xFFFF || m == 0 ? null : m;
  }

  static Uint8List encodeXy(XyColor c) => Uint8List.fromList([..._u16(_scale(c.x)), ..._u16(_scale(c.y))]);

  static XyColor? decodeXy(Uint8List bytes) {
    if (bytes.length < 4) return null;
    final x = bytes[0] | bytes[1] << 8;
    final y = bytes[2] | bytes[3] << 8;
    if (x == 0xFFFF && y == 0xFFFF) return null;
    return XyColor(x / 65536, y / 65536);
  }

  /// A 16-bit wire value: the spec clamps colour values to 1..65279.
  static int _wire16(int v) => v.clamp(1, 65279);

  /// An xy coordinate on the wire: round(coord x 65536), clamped 1..65279.
  static int _scale(double v) => _wire16((v * 65536).round());

  static List<int> _u16(int v) => [v & 0xFF, v >> 8 & 0xFF];
}
