// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/ble/ble_central.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';
import 'package:lumen/transport/ble/hue_ble_driver.dart';

void main() {
  test('knows the minimum dim level characteristic', () {
    expect(HueGatt.minDim, '932c32bd-1006-47a2-835a-a8d455b859dd');
  });

  test('the level is one byte, scaled as brightness (spec 5)', () {
    expect(HueBleCodec.encodeMinDim(0.0), [1]);
    expect(HueBleCodec.encodeMinDim(0.1), [26]);
    expect(HueBleCodec.encodeMinDim(1.0), [254]);
    expect(HueBleCodec.decodeMinDim(Uint8List.fromList([26])), closeTo(0.1, 0.002));
    expect(HueBleCodec.decodeMinDim(Uint8List.fromList([0xFF])), isNull);
    expect(HueBleCodec.decodeMinDim(Uint8List(0)), isNull);
  });

  group('driver', () {
    late SimulatedBleCentral central;
    late HueBleDriver driver;

    setUp(() {
      central = SimulatedBleCentral(scanDelay: Duration.zero);
      driver = HueBleDriver(central);
    });

    test('adding detects the characteristic', () async {
      central
        ..addBulb(SimulatedHueBulb(id: 'a'))
        ..addBulb(SimulatedHueBulb(id: 'b', hasMinDim: false));
      expect((await driver.add('a')).minDim, isTrue);
      expect((await driver.add('b')).minDim, isFalse);
    });

    test('the characteristic is write-only on a bulb, as the spec lists it (section 5)', () async {
      central.addBulb(SimulatedHueBulb(id: 'a', bonded: true));
      await central.connect('a');
      final read = await central
          .read('a', HueGatt.lightService, HueGatt.minDim)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(read, isA<BleOperationException>());
      expect((read as BleOperationException).kind, isNot(BleFailure.notFound));
    });

    test('adding detects a write-only characteristic by its presence', () async {
      central.addBulb(SimulatedHueBulb(id: 'a'));
      expect((await driver.add('a')).minDim, isTrue);
      expect(await driver.readMinDim('a'), isNull, reason: 'there is no value to read');
    });

    test('reads and writes the level as one byte with response', () async {
      final bulb = central.addBulb(SimulatedHueBulb(id: 'a', minDimReadable: true));
      await driver.add('a');
      expect(await driver.readMinDim('a'), 0);
      await driver.writeMinDim('a', 0.1);
      expect(bulb.writes.last.characteristic, HueGatt.minDim);
      expect(bulb.writes.last.value, [26]);
      expect(bulb.writes.last.withoutResponse, isFalse);
      expect(bulb.minDim, [26]);
    });
  });

  test('the controller remembers whether a light has it and sets it', () async {
    final central = SimulatedBleCentral(scanDelay: Duration.zero);
    final home = HomeController(
      AppServices.simulated(central: central, bridge: SimulatedBridge(), store: MemoryHomeStore()),
    );
    await home.load();
    final bulb = central.addBulb(SimulatedHueBulb(id: 'a', minDimReadable: true));
    final light = await home.addBluetoothLight(await home.scanBluetooth().first);
    expect(light.minDimConfigurable, isTrue);
    await home.setMinDim(light.id, 0.5);
    expect(bulb.minDim, [128]);
    expect(await home.minDim(light.id), closeTo(0.5, 0.002));
  });

  test('on a write-only bulb the controller offers the last level it wrote, kept across launches', () async {
    final central = SimulatedBleCentral(scanDelay: Duration.zero);
    final store = MemoryHomeStore();
    HomeController build() =>
        HomeController(AppServices.simulated(central: central, bridge: SimulatedBridge(), store: store));
    final home = build();
    await home.load();
    final bulb = central.addBulb(SimulatedHueBulb(id: 'a'));
    final light = await home.addBluetoothLight(await home.scanBluetooth().first);
    expect(light.minDimConfigurable, isTrue);
    expect(await home.minDim(light.id), isNull, reason: 'nothing written yet and nothing to read');
    await home.setMinDim(light.id, 0.25);
    expect(bulb.minDim, [64]);
    expect(home.light(light.id)!.minDimLevel, closeTo(0.25, 0.002));

    final again = build();
    await again.load();
    expect(again.light(light.id)!.minDimLevel, closeTo(0.25, 0.002));
    expect(await again.minDim(light.id), closeTo(0.25, 0.002));
  });
}
