// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:typed_data';

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

  const red = XyColor(0.675, 0.322);
  const blue = XyColor(0.1532, 0.0475);
  const green = XyColor(0.17, 0.7);

  void expectClose(List<XyColor> actual, List<XyColor> expected) {
    expect(actual, hasLength(expected.length));
    for (var i = 0; i < expected.length; i++) {
      expect(actual[i].x, closeTo(expected[i].x, 0.0005));
      expect(actual[i].y, closeTo(expected[i].y, 0.0005));
    }
  }

  test('a gradient strip takes a palette, power and mode in one write', () async {
    final strip = central.addBulb(SimulatedHueBulb(id: 's', model: 'LCX004'));
    await driver.add('s');
    final before = strip.writes.length;
    await driver.send(
      's',
      const LightCommand(on: true, gradient: LightGradient([red, green, blue], mode: GradientMode.mirrored)),
    );
    expect(strip.writes.length - before, 1);
    expect(strip.writes.last.characteristic, HueGatt.control);
    expect(strip.state.on, isTrue);
    expect(strip.state.gradient!.mode, GradientMode.mirrored);
    expectClose(strip.state.gradient!.colors, [red, green, blue]);
  });

  test('the strip reports its gradient back', () async {
    final strip = central.addBulb(SimulatedHueBulb(id: 's', model: 'LCX004'));
    await driver.add('s');
    await driver.send('s', const LightCommand(gradient: LightGradient([red, blue])));
    final state = await driver.readState('s');
    expectClose(state.gradient!.colors, [red, blue]);
    expect(strip.state.gradient, isNotNull);
  });

  test('a single colour replaces the gradient', () async {
    final strip = central.addBulb(SimulatedHueBulb(id: 's', model: 'LCX004'));
    await driver.add('s');
    await driver.send('s', const LightCommand(gradient: LightGradient([red, blue])));
    await driver.send('s', const LightCommand(color: green));
    expect(strip.state.gradient, isNull);
    expect((await driver.readState('s')).gradient, isNull);
  });

  test('a bulb without gradient support ignores a palette', () async {
    final bulb = central.addBulb(SimulatedHueBulb(id: 'b'));
    await driver.add('b');
    await driver.send('b', const LightCommand(on: true, gradient: LightGradient([red, blue])));
    expect(bulb.state.on, isTrue);
    expect(bulb.state.gradient, isNull);
  });

  test('the simulated strip refuses a palette whose header does not match its points', () {
    final strip = SimulatedHueBulb(id: 's', model: 'LCX004', bonded: true);
    // Header says three colours, but only one follows.
    final bad = Uint8List.fromList([0x07, 7, 0x30, 0x00, 0x00, 0x00, 0x88, 0xB6, 0x3C]);
    expect(() => strip.write(HueGatt.control, bad), throwsA(anything));
    final odd = Uint8List.fromList([0x07, 7, 0x10, 0x03, 0x00, 0x00, 0x88, 0xB6, 0x3C]);
    expect(() => strip.write(HueGatt.control, odd), throwsA(anything), reason: 'the mode byte is always even');
  });
}
