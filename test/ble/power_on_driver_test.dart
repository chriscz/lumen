// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/domain/power_on.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';
import 'package:lumen/transport/ble/hue_ble_driver.dart';

void main() {
  late SimulatedBleCentral central;
  late HueBleDriver driver;

  setUp(() {
    central = SimulatedBleCentral(scanDelay: Duration.zero);
    driver = HueBleDriver(central);
  });

  test('adding detects the startup characteristic', () async {
    central
      ..addBulb(SimulatedHueBulb(id: 'a'))
      ..addBulb(SimulatedHueBulb(id: 'b', hasStartup: false));
    expect((await driver.add('a')).powerOn, isTrue);
    expect((await driver.add('b')).powerOn, isFalse);
  });

  test('reads the startup behaviour the bulb holds', () async {
    central.addBulb(SimulatedHueBulb(id: 'a', startup: [0x01, 0x01, 0x00]));
    await driver.add('a');
    expect((await driver.readPowerOn('a'))!.mode, PowerOnMode.alwaysOff);
  });

  test('a bulb without the characteristic has no startup behaviour', () async {
    central.addBulb(SimulatedHueBulb(id: 'a', hasStartup: false));
    await driver.add('a');
    expect(await driver.readPowerOn('a'), isNull);
  });

  test('writes the startup records with response', () async {
    final bulb = central.addBulb(SimulatedHueBulb(id: 'a'));
    await driver.add('a');
    await driver.writePowerOn('a', PowerOnBehavior.lastState(LightKind.ambiance));
    expect(bulb.writes.last.characteristic, HueGatt.startup);
    expect(bulb.writes.last.withoutResponse, isFalse);
    expect(bulb.startup, [0x01, 0x01, 0xFF, 0x02, 0x01, 0xFF, 0x03, 0x02, 0xFF, 0xFF]);
  });

  test('the simulated bulb refuses a malformed startup record', () {
    final bulb = SimulatedHueBulb(id: 'a', bonded: true);
    expect(
      () => bulb.write(HueGatt.startup, HueBleCodec.encodeControl(const LightCommand(effect: HueEffect.candle))),
      throwsA(anything),
    );
    expect(bulb.startup, SimulatedHueBulb.defaultStartup);
  });
}
