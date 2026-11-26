// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/ble/ble_central.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';
import 'package:lumen/transport/ble/hue_ble_driver.dart';

void main() {
  late SimulatedBleCentral central;

  setUp(() => central = SimulatedBleCentral(scanDelay: Duration.zero));

  test('the simulated bulb refuses notifications on the encrypted control characteristic until bonded', () async {
    final bulb = central.addBulb(SimulatedHueBulb(id: 'a'));
    await central.connect('a');
    final refused = Completer<Object>();
    final sub = central
        .notifications('a', HueGatt.lightService, HueGatt.control)
        .listen((_) {}, onError: refused.complete);
    final error = await refused.future.timeout(const Duration(seconds: 1));
    expect((error as BleOperationException).kind, BleFailure.unauthenticated);
    expect(central.subscriptions, isEmpty);
    await sub.cancel();

    bulb.bond();
    final reports = <Object>[];
    final again = central.notifications('a', HueGatt.lightService, HueGatt.control).listen(reports.add);
    await pumpEventQueue();
    bulb.changeLocally(const LightCommand(on: true));
    await pumpEventQueue();
    expect(reports, hasLength(1));
    expect(central.subscriptions, [('a', HueGatt.control)]);
    await again.cancel();
  });

  test('a newly bonded bulb reports a wall-switch change to the driver', () async {
    final driver = HueBleDriver(central);
    final bulb = central.addBulb(SimulatedHueBulb(id: 'a'));
    await driver.add('a');
    expect(bulb.bonded, isTrue);
    final next = driver.reports.first.timeout(const Duration(seconds: 1));
    bulb.changeLocally(const LightCommand(on: true, brightness: 30));
    final report = await next;
    expect(report.deviceId, 'a');
    expect(report.state.brightness, 30);
  });

  test('a newly added light shows a wall-switch change', () async {
    final home = HomeController(
      AppServices.simulated(central: central, bridge: SimulatedBridge(), store: MemoryHomeStore()),
    );
    await home.load();
    final bulb = central.addBulb(SimulatedHueBulb(id: 'a', state: const LightState(on: false, brightness: 254)));
    final light = await home.addBluetoothLight(await home.scanBluetooth().first);
    bulb.changeLocally(const LightCommand(on: true));
    await pumpEventQueue();
    expect(home.light(light.id)!.state.on, isTrue);
  });
}
