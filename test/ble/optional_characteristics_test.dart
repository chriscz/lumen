// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/errors.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/ble/ble_central.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';
import 'package:lumen/transport/ble/hue_ble_driver.dart';

/// The characteristics a Hue bulb may lack, by service.
const optional = [
  (HueGatt.lightService, HueGatt.capabilities),
  (HueGatt.lightService, HueGatt.startup),
  (HueGatt.lightService, HueGatt.minDim),
  (HueGatt.lightService, HueGatt.identify),
  (HueGatt.configService, HueGatt.proximity),
  (HueGatt.configService, HueGatt.securityKey),
];

void main() {
  late SimulatedBleCentral central;
  late HueBleDriver driver;

  setUp(() {
    central = SimulatedBleCentral(scanDelay: Duration.zero);
    driver = HueBleDriver(central);
  });

  group('simulated central', () {
    test('knows which characteristics a connected bulb has', () async {
      central
        ..addBulb(SimulatedHueBulb(id: 'full', securityKey: SimulatedHueBulb.emptyKey))
        ..addBulb(SimulatedHueBulb.minimal(id: 'bare'));
      await central.connect('full');
      await central.connect('bare');
      for (final (service, characteristic) in optional) {
        expect(await central.hasCharacteristic('full', service, characteristic), isTrue, reason: characteristic);
        expect(await central.hasCharacteristic('bare', service, characteristic), isFalse, reason: characteristic);
      }
      expect(await central.hasCharacteristic('bare', HueGatt.lightService, HueGatt.control), isTrue);
    });

    test('a characteristic the bulb lacks fails with notFound, as on a real phone', () async {
      central.addBulb(SimulatedHueBulb.minimal(id: 'bare', bonded: true));
      await central.connect('bare');
      for (final (service, characteristic) in optional) {
        final read = await central
            .read('bare', service, characteristic)
            .then<Object?>((_) => null, onError: (Object e) => e);
        expect((read as BleOperationException).kind, BleFailure.notFound, reason: characteristic);
        final write = await central
            .write('bare', service, characteristic, Uint8List.fromList([1]))
            .then<Object?>((_) => null, onError: (Object e) => e);
        expect((write as BleOperationException).kind, BleFailure.notFound, reason: characteristic);
      }
    });
  });

  group('driver', () {
    test('adds a bulb without any optional characteristic', () async {
      final bulb = central.addBulb(SimulatedHueBulb.minimal(id: 'bare', name: 'Old lamp', model: 'LTW001'));
      final info = await driver.add('bare');
      expect(info.name, 'Old lamp');
      expect(info.kind, LightKind.ambiance);
      expect(info.capabilities, isNull);
      expect(info.powerOn, isFalse);
      expect(info.minDim, isFalse);
      expect(bulb.bonded, isTrue);
    });

    test('checks for an optional characteristic before reading it', () async {
      central.addBulb(SimulatedHueBulb.minimal(id: 'bare'));
      await driver.add('bare');
      expect((await driver.readFeatures('bare')).capabilities, isNull);
      expect(await driver.readPowerOn('bare'), isNull);
      expect(await driver.readMinDim('bare'), isNull);
      final asked = [for (final (_, c) in central.readRequests) c];
      for (final (_, characteristic) in optional) {
        expect(asked, isNot(contains(characteristic)));
      }
    });

    test('an optional probe that finds the characteristic gone treats it as absent', () async {
      central.addBulb(SimulatedHueBulb(id: 'a'));
      await driver.add('a');
      central.reportsAllCharacteristics = true;
      central.bulbs['a']!.startup = null;
      expect(await driver.readPowerOn('a'), isNull);
    });

    test('controls a bulb without any optional characteristic', () async {
      final bulb = central.addBulb(SimulatedHueBulb.minimal(id: 'bare'));
      await driver.add('bare');
      await driver.send('bare', const LightCommand(on: true, brightness: 80));
      expect(bulb.state.on, isTrue);
      expect(bulb.state.brightness, 80);
    });

    test('a control write on a stale GATT table reconnects once and succeeds', () async {
      final bulb = central.addBulb(SimulatedHueBulb(id: 'a'));
      await driver.add('a');
      central.staleGatt['a'] = 1;
      final connects = central.connects;
      await driver.send('a', const LightCommand(on: true));
      expect(bulb.state.on, isTrue);
      expect(central.connects, connects + 1);
    });

    test('a control write that still finds no characteristic fails with a clear error', () async {
      central.addBulb(SimulatedHueBulb(id: 'a'));
      await driver.add('a');
      central.staleGatt['a'] = 2;
      await expectLater(driver.send('a', const LightCommand(on: true)), throwsA(isA<CharacteristicMissing>()));
    });
  });

  test('the controller adds and switches a bulb without optional characteristics', () async {
    final home = HomeController(
      AppServices.simulated(central: central, bridge: SimulatedBridge(), store: MemoryHomeStore()),
    );
    await home.load();
    final bulb = central.addBulb(SimulatedHueBulb.minimal(id: 'bare'));
    final light = await home.addBluetoothLight(await home.scanBluetooth().first);
    expect(light.powerOnConfigurable, isFalse);
    expect(light.minDimConfigurable, isFalse);
    await home.setPower(light.id, true);
    expect(bulb.state.on, isTrue);
    expect(home.light(light.id)!.reachable, isTrue);
  });
}
