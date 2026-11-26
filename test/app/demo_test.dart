// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/emulator/bridge_server.dart';
import 'package:lumen/emulator/bridge_background.dart';
import 'package:lumen/emulator/multicast_lock.dart';
import 'package:lumen/emulator/nsd.dart';
import 'package:lumen/log/logger.dart';
import 'package:lumen/sim/demo.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/state/emulator_store.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/bridge/lan_bridge_discovery.dart';

void main() {
  test('the demo is marked as one and keeps the stores and log it is given', () {
    final store = MemoryHomeStore();
    final emulatorStore = MemoryEmulatorStore();
    final log = Logger.memory();
    final services = Demo.services(store: store, emulatorStore: emulatorStore, log: log);
    expect(services.demo, isTrue);
    expect(services.store, same(store));
    expect(services.emulatorStore, same(emulatorStore));
    expect(services.log, same(log));
  });

  test('the emulated Hue Bridge is real in demo mode', () {
    final services = Demo.services(store: MemoryHomeStore());
    expect(services.emulatorServer, BridgeServer.create, reason: 'real sockets, so other apps can pair');
    expect(services.multicast, isA<PlatformMulticastLock>());
    expect(services.background, isA<PlatformBridgeBackground>());
    expect(services.nsd, isA<PlatformNsd>());
  });

  test('three Bluetooth bulbs are nearby, the hallway already on', () {
    final central = Demo.services(store: MemoryHomeStore()).central as SimulatedBleCentral;
    expect(central.latency, const Duration(milliseconds: 60));
    expect(
      {for (final b in central.bulbs.values) b.id: (b.name, b.model)},
      {
        'c4:2c:00:00:00:01': ('Desk lamp', 'LCA006'),
        'c4:2c:00:00:00:02': ('Bedside', 'LTA001'),
        'c4:2c:00:00:00:03': ('Hallway', 'LWA001'),
      },
    );
    final hallway = central.bulbs['c4:2c:00:00:00:03']!;
    expect(hallway.state.on, isTrue);
    expect(hallway.state.brightness, 180);
    expect(central.bulbs['c4:2c:00:00:00:01']!.state.on, isFalse);
  });

  test('a bulb of the demo can be added and switched', () async {
    final home = HomeController(Demo.services(store: MemoryHomeStore()));
    await home.load();
    final found = await home.scanBluetooth().firstWhere((b) => b.name == 'Bedside');
    final light = await home.addBluetoothLight(found);
    expect(light.kind, LightKind.ambiance);
    await home.setPower(light.id, true);
    final central = home.services.central as SimulatedBleCentral;
    expect(central.bulbs['c4:2c:00:00:00:02']!.state.on, isTrue);
  });

  test('the demo bridge is discovered and pairs on its own, with three lights and their looks', () async {
    final home = HomeController(
      Demo.services(store: MemoryHomeStore(), linkButtonEvery: const Duration(milliseconds: 20)),
    );
    await home.load();
    final bridge = (await home.discoverBridges().firstWhere((e) => e is BridgeFound) as BridgeFound).bridge;

    final account = await home.pairBridge(bridge.address, interval: const Duration(milliseconds: 10));
    expect(account.name, 'Demo bridge');
    final lights = {for (final l in home.lights) l.name: l};
    expect(lights.keys, unorderedEquals(['Sofa', 'Kitchen', 'Lightstrip']));
    expect(lights['Sofa']!.state, const LightState(on: true, brightness: 200, color: XyColor(0.55, 0.38)));
    expect(lights['Kitchen']!.kind, LightKind.ambiance);
    expect(lights['Kitchen']!.isOn, isFalse);
    expect(lights['Lightstrip']!.state, const LightState(on: true, brightness: 120, color: XyColor(0.17, 0.12)));
  });
}
