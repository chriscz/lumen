// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/capabilities.dart';
import 'package:lumen/domain/light.dart';
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

  test('a simulated colour bulb serves its capabilities byte for byte', () {
    expect(SimulatedHueBulb.capabilitiesFor('LCA006'), [
      0x00, 0x01, 0x03, // colour
      0x01, 0x02, 0x99, 0x00, // 153 mireds
      0x02, 0x02, 0xF4, 0x01, // 500 mireds
      0x03, 0x01, 0x06, // dynamic scenes and effects
      0x04, 0x03, 0x0F, 0xFE, 0x03, // effect ids 0 to 3 and 9 to 17
    ]);
    expect(SimulatedHueBulb.capabilitiesFor('LWA001'), [0x00, 0x01, 0x01, 0x03, 0x01, 0x00]);
    expect(SimulatedHueBulb.capabilitiesFor('LOM001'), [0x03, 0x01, 0x00]);
  });

  test('adding reads the capabilities and takes the kind from the light type', () async {
    central.addBulb(SimulatedHueBulb(id: 'a', model: 'LCA006', capabilities: [0x00, 0x01, 0x02]));
    final info = await driver.add('a');
    expect(info.kind, LightKind.ambiance);
    expect(info.capabilities?.lightType, 2);
    expect(central.bulbs['a']!.reads, contains(HueGatt.capabilities));
  });

  test('a light without a light type record is an on/off light', () async {
    central.addBulb(SimulatedHueBulb(id: 'a', model: 'LOM001'));
    final info = await driver.add('a');
    expect(info.kind, LightKind.onOff);
  });

  test('a colour bulb reports its temperature range and effects', () async {
    central.addBulb(SimulatedHueBulb(id: 'a'));
    final caps = (await driver.add('a')).capabilities!;
    expect(caps.minMireds, 153);
    expect(caps.maxMireds, 500);
    expect(caps.effects, contains(HueEffect.candle));
  });

  test('without the characteristic, the model number decides the kind', () async {
    central.addBulb(SimulatedHueBulb(id: 'a', model: 'LTA001', hasCapabilities: false));
    final info = await driver.add('a');
    expect(info.kind, LightKind.ambiance);
    expect(info.capabilities, isNull);
  });

  test('an unknown light type falls back to the model number', () async {
    central.addBulb(SimulatedHueBulb(id: 'a', model: 'LWA001', capabilities: [0x00, 0x01, 0x09]));
    expect((await driver.add('a')).kind, LightKind.white);
  });

  test('capabilities can be read again on connect', () async {
    central.addBulb(SimulatedHueBulb(id: 'a', model: 'LCX004'));
    await driver.add('a');
    final caps = (await driver.readFeatures('a')).capabilities;
    expect(caps!.gradient, isTrue);
    expect(caps.gradientModes, GradientMode.values.toSet());
  });
}
