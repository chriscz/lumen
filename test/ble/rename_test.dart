// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';

void main() {
  group('name encoding (spec 5)', () {
    test('a short name is plain UTF-8', () {
      expect(HueBleCodec.encodeName('Desk'), utf8.encode('Desk'));
      expect(HueBleCodec.encodeName('Café'), utf8.encode('Café'));
    });

    test('a long name is cut to 32 bytes', () {
      final bytes = HueBleCodec.encodeName('A' * 40);
      expect(bytes, hasLength(32));
    });

    test('the cut never splits a character', () {
      // 31 ASCII bytes then a two-byte e acute: the e acute does not fit.
      expect(HueBleCodec.encodeName('${'a' * 31}é'), utf8.encode('a' * 31));
      // Four-byte emoji: eight fit in 32 bytes, the ninth does not.
      final emoji = '\u{1F4A1}' * 9;
      final bytes = HueBleCodec.encodeName(emoji);
      expect(bytes, hasLength(32));
      expect(utf8.decode(bytes), '\u{1F4A1}' * 8);
    });
  });

  group('rename', () {
    late SimulatedBleCentral central;
    late HomeController home;

    setUp(() async {
      central = SimulatedBleCentral(scanDelay: Duration.zero);
      home = HomeController(
        AppServices.simulated(central: central, bridge: SimulatedBridge(), store: MemoryHomeStore()),
      );
      await home.load();
      central.addBulb(SimulatedHueBulb(id: 'a', name: 'Hue color lamp 1'));
      await home.addBluetoothLight(await home.scanBluetooth().first);
    });

    test('renaming a Bluetooth light writes the name to the bulb too', () async {
      await home.rename('ble:a', 'Reading lamp');
      expect(home.light('ble:a')!.name, 'Reading lamp');
      expect(central.bulbs['a']!.name, 'Reading lamp');
      expect(central.bulbs['a']!.writes.last.characteristic, HueGatt.name);
    });

    test('a long name is kept whole in the app and cut on the bulb', () async {
      final long = 'The lamp on the left of the big bookshelf';
      await home.rename('ble:a', long);
      expect(home.light('ble:a')!.name, long);
      expect(central.bulbs['a']!.name, long.substring(0, 32));
    });

    test('the app name changes even when the bulb is out of reach', () async {
      central.dropConnection('a');
      central.bulbs['a']!.inRange = false;
      await home.rename('ble:a', 'Porch');
      expect(home.light('ble:a')!.name, 'Porch');
      expect(central.bulbs['a']!.name, 'Hue color lamp 1');
    });
  });
}
