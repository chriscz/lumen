// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/domain/home.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/bridge/hue_bridge_client.dart';

void main() {
  late SimulatedBridge bridge;
  late MemoryHomeStore store;
  late HomeController home;

  HomeController controller() {
    final http.Client client = MockClient((request) async {
      final (status, body) = bridge.handle(request.method, request.url.path, request.body);
      return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
    });
    return HomeController(
      AppServices(
        central: SimulatedBleCentral(scanDelay: Duration.zero),
        bridgeClient: (host) => HueBridgeClient(client, Uri.parse('http://$host')),
        store: store,
      ),
    );
  }

  setUp(() async {
    store = MemoryHomeStore();
    bridge = SimulatedBridge();
    for (final name in ['Sofa', 'Lamp', 'Hall']) {
      bridge.addLight(SimulatedBridgeLight(name: name));
    }
    home = controller();
    await home.load();
    bridge.pressLinkButton();
    await home.pairBridge('192.168.1.2', interval: Duration.zero);
  });

  String id(String lightId) => HomeController.bridgeLightId(bridge.id, lightId);
  List<String> names() => [for (final l in home.lights) l.name];
  BridgeAccount account() => home.bridges.single;

  test('a removed bridge light stays removed when the bridge is read again, and after a restart', () async {
    await home.remove(id('2'));
    await home.refresh();
    expect(names(), ['Sofa', 'Hall']);
    expect(account().removedLights, {'2': 'Lamp'});

    final again = controller();
    await again.load();
    await again.refresh();
    expect([for (final l in again.lights) l.name], ['Sofa', 'Hall']);
  });

  test('a removed light can be added back, alone or with all the others', () async {
    await home.remove(id('1'));
    await home.remove(id('3'));
    await home.addBridgeLightBack(bridge.id, '3');
    expect(names(), unorderedEquals(['Lamp', 'Hall']));
    expect(account().removedLights, {'1': 'Sofa'});

    await home.addAllBridgeLightsBack(bridge.id);
    expect(names(), unorderedEquals(['Sofa', 'Lamp', 'Hall']));
    expect(account().removedLights, isEmpty);
  });

  test('undoing a removal puts the light back for good', () async {
    final lamp = home.light(id('2'))!;
    await home.remove(lamp.id);
    await home.restore(lamp);
    await home.refresh();
    expect(names(), unorderedEquals(['Sofa', 'Lamp', 'Hall']));
    expect(account().removedLights, isEmpty);
  });

  test('a light the bridge no longer has drops off the removed list', () async {
    await home.remove(id('2'));
    bridge.lights.remove('2');
    await home.refresh();
    expect(account().removedLights, isEmpty);
  });

  test('the removed lights are kept with the bridge account, and older saves have none', () {
    const a = BridgeAccount(id: 'b', name: 'Hue', host: 'h', appKey: 'k', removedLights: {'2': 'Lamp'});
    expect(BridgeAccount.fromJson(a.toJson()).removedLights, {'2': 'Lamp'});
    expect(BridgeAccount.fromJson({'id': 'b', 'name': 'Hue', 'host': 'h', 'appKey': 'k'}).removedLights, isEmpty);
  });
}
