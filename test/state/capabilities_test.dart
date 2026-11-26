// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/home.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';

class CountingStore extends MemoryHomeStore {
  int saves = 0;

  @override
  Future<void> save(HomeSnapshot snapshot) {
    saves++;
    return super.save(snapshot);
  }
}

void main() {
  late SimulatedBleCentral central;
  late CountingStore store;
  late HomeController home;

  HomeController build() =>
      HomeController(AppServices.simulated(central: central, bridge: SimulatedBridge(), store: store));

  setUp(() async {
    central = SimulatedBleCentral(scanDelay: Duration.zero);
    store = CountingStore();
    home = build();
    await home.load();
  });

  Future<Light> add(SimulatedHueBulb bulb) async {
    central.addBulb(bulb);
    final found = await home.scanBluetooth().firstWhere((b) => b.deviceId == bulb.id);
    return home.addBluetoothLight(found);
  }

  test('a light keeps its capabilities, also across a restart', () async {
    final light = await add(SimulatedHueBulb(id: 'a', model: 'LTA001'));
    expect(light.capabilities?.maxMireds, 454);
    home = build();
    await home.load();
    expect(home.light(light.id)!.capabilities?.maxMireds, 454);
    expect(home.light(light.id)!.kind, LightKind.ambiance);
  });

  test('connecting reads the capabilities of a light added before they existed', () async {
    final light = await add(SimulatedHueBulb(id: 'a', model: 'LCA006', capabilities: [0x00, 0x01, 0x02]));
    await home.remove(light.id);
    await home.restore(Light(id: light.id, name: light.name, transport: Transport.ble, address: 'a'));
    expect(home.light(light.id)!.capabilities, isNull);
    await home.connectAll();
    expect(home.light(light.id)!.capabilities?.lightType, 2);
    expect(home.light(light.id)!.kind, LightKind.ambiance);
  });

  int capabilityReads() => central.readRequests.where((r) => r.$2 == HueGatt.capabilities).length;

  test('each launch reads a bulb\'s capabilities at most once', () async {
    await add(SimulatedHueBulb(id: 'a'));
    await add(SimulatedHueBulb(id: 'b'));
    home = build();
    await home.load();
    central.readRequests.clear();
    await home.connectAll();
    expect(capabilityReads(), 2);
    await home.connectAll();
    await home.connectAll();
    expect(capabilityReads(), 2, reason: 'a resume does not read them again');
  });

  test('a light just added is not probed again when the app connects', () async {
    await add(SimulatedHueBulb(id: 'a'));
    central.readRequests.clear();
    await home.connectAll();
    expect(capabilityReads(), 0);
  });

  test('unchanged capabilities are not saved, and changes are saved once', () async {
    final bulbs = [
      for (final id in ['a', 'b', 'c']) SimulatedHueBulb(id: id),
    ];
    for (final b in bulbs) {
      await add(b);
    }
    home = build();
    await home.load();
    store.saves = 0;
    await home.connectAll();
    expect(store.saves, 0);

    bulbs[0].capabilities = [0x00, 0x01, 0x02];
    bulbs[1].startup = null;
    home = build();
    await home.load();
    store.saves = 0;
    await home.connectAll();
    expect(store.saves, 1);
    expect(home.light('ble:a')!.kind, LightKind.ambiance);
    expect(home.light('ble:b')!.powerOnConfigurable, isFalse);
  });

  test('effects are the ones the light lists', () async {
    final light = await add(SimulatedHueBulb(id: 'a', capabilities: [0x00, 0x01, 0x03, 0x04, 0x01, 0x06]));
    expect(home.light(light.id)!.effects, [HueEffect.candle, HueEffect.fireplace]);
  });

  test('a colour light that lists no effects offers none', () async {
    final light = await add(SimulatedHueBulb(id: 'a', capabilities: [0x00, 0x01, 0x03, 0x03, 0x01, 0x00]));
    expect(home.light(light.id)!.effects, isEmpty);
  });

  test('without capabilities a colour bulb offers every effect, as before', () async {
    final light = await add(SimulatedHueBulb(id: 'a', hasCapabilities: false));
    expect(home.light(light.id)!.effects, HueEffect.values.where((e) => e != HueEffect.none));
  });

  test('colour temperatures stay inside the range the light reports', () async {
    final light = await add(SimulatedHueBulb(id: 'a', model: 'LTA001'));
    expect(home.light(light.id)!.miredsRange, (153, 454));
    await home.setColor(light.id, const WhiteColor(500));
    expect(central.bulbs['a']!.state.color, const WhiteColor(454));
  });
}
