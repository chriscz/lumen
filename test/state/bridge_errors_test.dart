// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/domain/errors.dart';
import 'package:lumen/domain/home.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/bridge/hue_bridge_client.dart';

class _CountingStore extends MemoryHomeStore {
  int saves = 0;

  @override
  Future<void> save(HomeSnapshot snapshot) {
    saves++;
    return super.save(snapshot);
  }
}

void main() {
  late SimulatedBridge bridge;
  late HomeController home;
  late _CountingStore store;

  /// When on, the bridge answers every request but the list of its groups.
  var groupsDown = false;

  setUp(() async {
    groupsDown = false;
    store = _CountingStore();
    bridge = SimulatedBridge();
    for (var i = 1; i <= 5; i++) {
      bridge.addLight(SimulatedBridgeLight(name: 'Light $i'));
    }
    bridge.addGroup('Lounge', ['1', '2', '3']);
    final http.Client client = MockClient((request) async {
      if (groupsDown && request.method == 'GET' && request.url.path.endsWith('/groups')) {
        return http.Response('{"error": "busy"}', 503);
      }
      final (status, body) = bridge.handle(request.method, request.url.path, request.body);
      return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
    });
    home = HomeController(
      AppServices(
        central: SimulatedBleCentral(scanDelay: Duration.zero),
        bridgeClient: (host) => HueBridgeClient(client, Uri.parse('http://$host')),
        store: store,
      ),
    );
    await home.load();
  });

  Future<void> pair() async {
    bridge.pressLinkButton();
    await home.pairBridge('192.168.1.2', interval: Duration.zero);
  }

  String id(String lightId) => HomeController.bridgeLightId(bridge.id, lightId);

  test('a bridge whose rooms cannot be read still pairs with all its lights, and no rooms', () async {
    groupsDown = true;
    await pair();
    expect(home.bridges.single.id, bridge.id);
    expect(home.lights, hasLength(5));
    expect(home.rooms, isEmpty);
    final saved = await store.load();
    expect(saved.bridges.single.id, bridge.id, reason: 'the bridge is saved without its rooms');
  });

  test('a refresh saves only when a light changed', () async {
    await pair();
    store.saves = 0;
    await home.refresh();
    expect(store.saves, 0, reason: 'nothing changed');
    bridge.lights['1']!.state = const LightState(on: true, brightness: 10);
    await home.refresh();
    expect(store.saves, 1);
    expect(home.light(id('1'))!.state.brightness, 10);
  });

  test('a refresh that cannot read the groups keeps the ones it knew', () async {
    await pair();
    final lounge = home.rooms.single;
    groupsDown = true;
    await home.refresh();
    bridge.requests.clear();
    await home.setRoomPower(lounge.id, true);
    expect(bridge.requests, ['PUT /groups/1/action'], reason: 'one group action, not three light calls');
    expect([
      for (final l in ['1', '2', '3']) bridge.lights[l]!.state.on,
    ], everyElement(isTrue));
  });

  test('a bridge that is down marks its lights unreachable and reports the error', () async {
    await pair();
    final errors = <LightError>[];
    home.errors.listen(errors.add);
    bridge.failAll = true;
    await home.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(home.lights.map((l) => l.reachable), everyElement(isFalse));
    expect(errors.single, isA<BridgeUnreachable>());
  });

  test('a quiet refresh, as in background polling, marks the lights but reports nothing', () async {
    await pair();
    final errors = <LightError>[];
    home.errors.listen(errors.add);
    bridge.failAll = true;
    await home.refresh(quiet: true);
    await Future<void>.delayed(Duration.zero);
    expect(home.lights.map((l) => l.reachable), everyElement(isFalse));
    expect(errors, isEmpty);

    bridge.failAll = false;
    await home.refresh(quiet: true);
    expect(home.lights.map((l) => l.reachable), everyElement(isTrue), reason: 'back once the bridge answers');
  });

  test('without every light of the bridge, all off never uses the all-lights group', () async {
    await pair();
    await home.remove(id('5'));
    await home.sendAll(home.lights.map((l) => l.id), const LightCommand(on: true));
    bridge.lights['5']!.state = const LightState(on: true);
    bridge.requests.clear();

    await home.allOff();
    expect(bridge.requests, unorderedEquals(['PUT /groups/1/action', 'PUT /lights/4/state']));
    expect(bridge.lights['5']!.state.on, isTrue, reason: 'the app does not hold light 5, so it is left alone');
    expect([
      for (final l in ['1', '2', '3', '4']) bridge.lights[l]!.state.on,
    ], everyElement(isFalse));
  });
}
