// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
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

  const singles = [HueGatt.power, HueGatt.brightness, HueGatt.temperature, HueGatt.xy];

  test('state is read from the combined control characteristic alone (spec 2, 4.2)', () async {
    final bulb = central.addBulb(
      SimulatedHueBulb(
        id: 'a',
        state: const LightState(on: true, brightness: 90, color: XyColor(0.4, 0.3)),
      ),
    );
    final info = await driver.add('a');
    expect(info.state.on, isTrue);
    expect(info.state.brightness, 90);
    expect((info.state.color as XyColor).x, closeTo(0.4, 0.0001));
    bulb.reads.clear();
    final state = await driver.readState('a');
    expect(state.brightness, 90);
    expect(bulb.reads, [HueGatt.control]);
    expect(bulb.reads.where(singles.contains), isEmpty);
  });

  test('falls back to the single-value characteristics when 0007 cannot be read', () async {
    final bulb = central.addBulb(
      SimulatedHueBulb(
        id: 'a',
        controlReadable: false,
        state: const LightState(on: true, brightness: 60, color: WhiteColor(300)),
      ),
    );
    final info = await driver.add('a');
    expect(info.state, const LightState(on: true, brightness: 60, color: WhiteColor(300)));
    expect(bulb.reads, containsAll([HueGatt.power, HueGatt.brightness]));
  });

  test('subscribes to the combined control characteristic only', () async {
    central.addBulb(SimulatedHueBulb(id: 'a'));
    await driver.add('a');
    expect(central.subscriptions, [('a', HueGatt.control)]);
  });
}
