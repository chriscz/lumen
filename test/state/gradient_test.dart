// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/capabilities.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';

void main() {
  late SimulatedBleCentral central;
  late HomeController home;

  setUp(() async {
    central = SimulatedBleCentral(scanDelay: Duration.zero);
    home = HomeController(AppServices.simulated(central: central, bridge: SimulatedBridge(), store: MemoryHomeStore()));
    await home.load();
  });

  Future<Light> add(SimulatedHueBulb bulb) async {
    central.addBulb(bulb);
    return home.addBluetoothLight(await home.scanBluetooth().firstWhere((b) => b.deviceId == bulb.id));
  }

  const gradient = LightGradient([XyColor(0.675, 0.322), XyColor(0.1532, 0.0475)], mode: GradientMode.segmented);

  test('a gradient strip offers gradients with the modes it lists', () async {
    final strip = await add(SimulatedHueBulb(id: 's', model: 'LCX004'));
    expect(home.light(strip.id)!.supportsGradient, isTrue);
    expect(home.light(strip.id)!.gradientModes, GradientMode.values);
    final bulb = await add(SimulatedHueBulb(id: 'b'));
    expect(home.light(bulb.id)!.supportsGradient, isFalse);
  });

  test('a strip that lists no modes offers interpolated only', () async {
    final strip = await add(SimulatedHueBulb(id: 's', capabilities: [0x00, 0x01, 0x03, 0x03, 0x01, 0x08]));
    expect(home.light(strip.id)!.gradientModes, [GradientMode.interpolated]);
  });

  test('setting a gradient switches the strip on and shows it at once', () async {
    final strip = await add(SimulatedHueBulb(id: 's', model: 'LCX004'));
    final done = home.setGradient(strip.id, gradient);
    expect(home.light(strip.id)!.state.gradient, gradient);
    await done;
    expect(central.bulbs['s']!.state.on, isTrue);
    expect(central.bulbs['s']!.state.gradient!.mode, GradientMode.segmented);
  });

  test('a plain colour clears the gradient', () async {
    final strip = await add(SimulatedHueBulb(id: 's', model: 'LCX004'));
    await home.setGradient(strip.id, gradient);
    await home.setColor(strip.id, const XyColor(0.17, 0.7));
    expect(home.light(strip.id)!.state.gradient, isNull);
    expect(central.bulbs['s']!.state.gradient, isNull);
  });
}
