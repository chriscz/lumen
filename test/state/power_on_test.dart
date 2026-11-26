// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/domain/power_on.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';

void main() {
  late SimulatedBleCentral central;
  late MemoryHomeStore store;
  late HomeController home;

  HomeController build() =>
      HomeController(AppServices.simulated(central: central, bridge: SimulatedBridge(), store: store));

  setUp(() async {
    central = SimulatedBleCentral(scanDelay: Duration.zero);
    store = MemoryHomeStore();
    home = build();
    await home.load();
  });

  Future<Light> add(SimulatedHueBulb bulb) async {
    central.addBulb(bulb);
    return home.addBluetoothLight(await home.scanBluetooth().firstWhere((b) => b.deviceId == bulb.id));
  }

  test('a bulb with the startup characteristic can set its power-on behaviour, across restarts', () async {
    final light = await add(SimulatedHueBulb(id: 'a'));
    expect(light.powerOnConfigurable, isTrue);
    home = build();
    await home.load();
    expect(home.light(light.id)!.powerOnConfigurable, isTrue);
  });

  test('a bulb without it cannot', () async {
    final light = await add(SimulatedHueBulb(id: 'a', hasStartup: false));
    expect(light.powerOnConfigurable, isFalse);
  });

  test('reads and sets the power-on behaviour', () async {
    final light = await add(
      SimulatedHueBulb(
        id: 'a',
        state: const LightState(on: true, brightness: 120, color: WhiteColor(400)),
      ),
    );
    expect((await home.powerOnBehavior(light.id))!.mode, PowerOnMode.alwaysOn);
    await home.setPowerOnMode(light.id, PowerOnMode.alwaysOff);
    expect((await home.powerOnBehavior(light.id))!.mode, PowerOnMode.alwaysOff);
    await home.setPowerOnMode(light.id, PowerOnMode.alwaysOn);
    expect(central.bulbs['a']!.startup, [0x01, 0x01, 0x01, 0x02, 0x01, 120, 0x03, 0x02, 0x90, 0x01]);
  });

  test('the next launch notices a bulb that gained or lost the characteristic', () async {
    final light = await add(SimulatedHueBulb(id: 'a', hasStartup: false));
    central.bulbs['a']!.startup = SimulatedHueBulb.defaultStartup;
    home = build();
    await home.load();
    await home.connectAll();
    expect(home.light(light.id)!.powerOnConfigurable, isTrue);
  });
}
