// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_bridge.dart';

void main() {
  late SimulatedBridge bridge;
  late String key;

  /// One call through the bridge, decoded as a client would see it.
  (int, Object?) call(String method, String path, [Object? body]) {
    final (status, json) = bridge.handle(method, path, body == null ? '' : jsonEncode(body));
    return (status, jsonDecode(jsonEncode(json)));
  }

  setUp(() {
    bridge = SimulatedBridge()
      ..addLight(SimulatedBridgeLight(name: 'Sofa'))
      ..addLight(SimulatedBridgeLight(name: 'Hall', type: 'Dimmable light'))
      ..addGroup('Lounge', ['1']);
    bridge.pressLinkButton();
    final (_, json) = call('POST', '/api', {'devicetype': 'test#sim'});
    key = ((json! as List).single as Map)['success']['username'] as String;
  });

  test('a group or light that does not exist is error 3 and changes nothing', () {
    final (groupStatus, group) = call('PUT', '/api/$key/groups/9/action', {'on': true});
    expect(groupStatus, 200);
    expect(((group! as List).single as Map)['error'], containsPair('type', 3));
    final (lightStatus, light) = call('PUT', '/api/$key/lights/9/state', {'on': true});
    expect(lightStatus, 200);
    expect(((light! as List).single as Map)['error'], containsPair('address', '/lights/9'));
    expect(bridge.lights.values.every((l) => l.state.on == false), isTrue);
    expect(bridge.requests, ['PUT /groups/9/action', 'PUT /lights/9/state']);
  });

  test('a call it does not model is a 404 with error 4', () {
    final (status, json) = call('DELETE', '/api/$key/lights/1');
    expect(status, 404);
    expect(((json! as List).single as Map)['error'], {
      'type': 4,
      'address': '/api/$key/lights/1',
      'description': 'method not available',
    });
  });

  test('a light set to an xy colour reads back in xy mode, and a white light ignores xy', () {
    call('PUT', '/api/$key/groups/0/action', {
      'on': true,
      'xy': [0.3, 0.4],
    });
    final (_, json) = call('GET', '/api/$key/lights');
    final lights = json! as Map;
    expect(lights['1']['state'], {
      'on': true,
      'bri': 254,
      'reachable': true,
      'xy': [0.3, 0.4],
      'colormode': 'xy',
    });
    expect(lights['1']['modelid'], 'LCT015');
    expect(lights['2']['state']['colormode'], 'ct');
    expect(lights['2']['modelid'], 'LWB010');
    expect(bridge.lights['1']!.state.color, const XyColor(0.3, 0.4));
  });

  test('an offline bridge answers nothing through its client', () async {
    bridge.offline = true;
    await expectLater(bridge.client().get(Uri.parse('http://bridge/api/config')), throwsA(isA<http.ClientException>()));
    bridge.offline = false;
    expect((await bridge.client().get(Uri.parse('http://bridge/api/config'))).statusCode, 200);
  });
}
