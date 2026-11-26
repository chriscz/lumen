// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/color/color_math.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/emulator/bridge_api.dart';
import 'package:lumen/emulator/emulator_settings.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';

void main() {
  late SimulatedBleCentral central;
  late SimulatedBridge bridge;
  late HomeController home;
  late EmulatorSettings settings;
  late BridgeApi api;
  late DateTime now;
  late int changes;

  // App lights in order: Desk (colour bulb), Hall (white bulb), then the
  // real bridge's Sofa and Kitchen (both colour).
  late String desk, hall, sofa, kitchen;

  BridgeApi build() => BridgeApi(home, settings, clock: () => now, random: Random(3), onChanged: () => changes++);

  setUp(() async {
    now = DateTime.utc(2026, 10, 23, 12);
    changes = 0;
    central = SimulatedBleCentral(scanDelay: Duration.zero)
      ..addBulb(SimulatedHueBulb(id: 'aa', name: 'Desk'))
      ..addBulb(SimulatedHueBulb(id: 'bb', name: 'Hall', model: 'LWA001'));
    bridge = SimulatedBridge(id: '001788fffe000001', name: 'Real bridge')
      ..addLight(SimulatedBridgeLight(name: 'Sofa'))
      ..addLight(SimulatedBridgeLight(name: 'Kitchen'))
      ..addGroup('Lounge', ['1', '2']);
    home = HomeController(AppServices.simulated(central: central, bridge: bridge, store: MemoryHomeStore()));
    await home.load();
    for (final id in ['aa', 'bb']) {
      final found = await home.scanBluetooth().firstWhere((b) => b.deviceId == id);
      await home.addBluetoothLight(found);
    }
    bridge.pressLinkButton();
    await home.pairBridge('192.168.1.2', interval: const Duration(milliseconds: 5));
    [desk, hall, sofa, kitchen] = [for (final l in home.lights) l.id];
    settings = EmulatorSettings(mac: 'aa:bb:cc:dd:ee:ff', name: 'Lumen');
    api = build();
  });

  tearDown(() => home.dispose());

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 400 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue, reason: 'condition not met in time');
  }

  Object? call(String method, String path, [Object? body]) {
    final (status, json) = api.handle(method, path, body == null ? '' : jsonEncode(body));
    expect(status, 200, reason: '$method $path');
    // Every answer must survive the wire.
    return jsonDecode(jsonEncode(json));
  }

  String pair([String devicetype = 'test#client']) {
    api.pressLinkButton();
    final json = call('POST', '/api', {'devicetype': devicetype}) as List;
    return (json.single as Map)['success']['username'] as String;
  }

  Map<String, Object?> errorOf(Object? json) => ((json as List).single as Map)['error'] as Map<String, Object?>;

  group('config', () {
    test('GET /api/config answers without a key with the short config', () {
      final json = call('GET', '/api/config') as Map;
      expect(json['name'], 'Lumen');
      expect(json['bridgeid'], 'AABBCCFFFEDDEEFF');
      expect(json['modelid'], 'BSB002');
      expect(json['mac'], 'aa:bb:cc:dd:ee:ff');
      expect(json['apiversion'], '1.56.0');
      expect(json['swversion'], isA<String>());
      expect(json['datastoreversion'], isA<String>());
      expect(json['factorynew'], isFalse);
      expect(json.containsKey('whitelist'), isFalse);
    });

    test('a new emulator gets a random, locally administered MAC that survives JSON', () {
      final created = EmulatorSettings.create(random: Random(9));
      final first = int.parse(created.mac.substring(0, 2), radix: 16);
      expect(created.mac, matches(RegExp(r'^([0-9a-f]{2}:){5}[0-9a-f]{2}$')));
      expect(first & 0x02, 0x02, reason: 'locally administered');
      expect(first & 0x01, 0, reason: 'unicast');
      final back = EmulatorSettings.fromJson(jsonDecode(jsonEncode(created.toJson())) as Map<String, Object?>);
      expect(back.mac, created.mac);
      expect(back.bridgeId, created.bridgeId);
      expect(EmulatorSettings.create(random: Random(10)).mac, isNot(created.mac));
    });

    test('GET /api/<key>/config has the whitelist and link button state', () {
      final key = pair('home#assistant');
      final json = call('GET', '/api/$key/config') as Map;
      expect(json['bridgeid'], 'AABBCCFFFEDDEEFF');
      expect(json['whitelist'][key]['name'], 'home#assistant');
      expect(json['linkbutton'], isTrue);
      expect(json['zigbeechannel'], isA<int>());
    });

    test('GET /api/<unknown key>/config answers with the short config, like a bridge', () {
      final json = call('GET', '/api/nouser/config') as Map;
      expect(json['bridgeid'], 'AABBCCFFFEDDEEFF');
      expect(json.containsKey('whitelist'), isFalse);
    });

    test('PUT /api/<key>/config renames the bridge', () {
      final key = pair();
      final json = call('PUT', '/api/$key/config', {'name': 'Upstairs'});
      expect(json, [
        {
          'success': {'/config/name': 'Upstairs'},
        },
      ]);
      expect(settings.name, 'Upstairs');
      expect(changes, greaterThan(0));
    });
  });

  group('pairing', () {
    test('POST /api before the link button is pressed fails with error 101', () {
      final json = call('POST', '/api', {'devicetype': 'x#y'});
      expect(errorOf(json)['type'], 101);
      expect(errorOf(json)['description'], 'link button not pressed');
    });

    test('POST /api within 30 seconds of the link button returns a username and stores the app', () {
      final key = pair('home#assistant');
      expect(key.length, greaterThanOrEqualTo(32));
      expect(settings.users[key]!.devicetype, 'home#assistant');
      expect(changes, greaterThan(0));
    });

    test('the link button window closes after 30 seconds', () {
      api.pressLinkButton();
      expect(api.linkButtonActive, isTrue);
      now = now.add(const Duration(seconds: 29));
      expect(api.linkButtonRemaining, const Duration(seconds: 1));
      now = now.add(const Duration(seconds: 2));
      expect(api.linkButtonActive, isFalse);
      expect(errorOf(call('POST', '/api', {'devicetype': 'x#y'}))['type'], 101);
    });

    test('generateclientkey returns a client key too', () {
      api.pressLinkButton();
      final json = call('POST', '/api', {'devicetype': 'x#y', 'generateclientkey': true}) as List;
      final success = (json.single as Map)['success'] as Map;
      expect(success['clientkey'], matches(RegExp(r'^[0-9A-F]{32}$')));
      expect(settings.users[success['username']]!.clientkey, success['clientkey']);
    });

    test('POST /api without a devicetype is an invalid parameter (type 5)', () {
      api.pressLinkButton();
      expect(errorOf(call('POST', '/api', {'name': 'x'}))['type'], 5);
    });

    test('a body that is not JSON is error type 2', () {
      final (status, json) = api.handle('POST', '/api', '{not json');
      expect(status, 200);
      expect(errorOf(json)['type'], 2);
    });

    test('an unknown key is error type 1', () {
      final json = call('GET', '/api/nobody/lights');
      expect(errorOf(json), {'type': 1, 'address': '/', 'description': 'unauthorized user'});
    });

    test('DELETE /api/<key>/config/whitelist/<other> revokes that app', () {
      final key = pair('a#b');
      final other = pair('c#d');
      call('DELETE', '/api/$key/config/whitelist/$other');
      expect(settings.users.keys, [key]);
      expect(errorOf(call('GET', '/api/$other/lights'))['type'], 1);
    });
  });

  group('last seen', () {
    test('every authorised request marks the app seen, saved at most once a minute', () {
      final key = pair();
      call('GET', '/api/$key/lights');
      call('GET', '/api/$key/lights');
      final first = changes;
      expect(settings.users[key]!.lastUsed, now);
      expect(api.takeUnsavedSeen(), isFalse, reason: 'pairing saved it');

      now = now.add(const Duration(seconds: 20));
      call('GET', '/api/$key/lights');
      expect(settings.users[key]!.lastUsed, now);
      expect(changes, first, reason: 'not saved again within the minute');
      expect(api.takeUnsavedSeen(), isTrue);
      expect(api.takeUnsavedSeen(), isFalse, reason: 'taken once');

      now = now.add(const Duration(seconds: 41));
      call('GET', '/api/$key/config');
      expect(changes, first + 1, reason: 'a minute after the last save');
      expect(api.takeUnsavedSeen(), isFalse);
    });

    test('an unauthorised request marks nobody seen', () {
      final key = pair();
      final before = settings.users[key]!.lastUsed;
      now = now.add(const Duration(minutes: 3));
      call('GET', '/api/config');
      call('GET', '/api/nobody/lights');
      expect(settings.users[key]!.lastUsed, before);
    });

    test('onSeen fires when an app becomes active, not on every request', () {
      final seen = <String>[];
      api = BridgeApi(home, settings, clock: () => now, random: Random(3), onSeen: seen.add);
      final key = pair();
      expect(seen, isEmpty, reason: 'pairing is not a request of the app');
      call('GET', '/api/$key/lights');
      expect(seen, isEmpty, reason: 'it was just paired, so already active');
      now = now.add(const Duration(minutes: 6));
      call('GET', '/api/$key/lights');
      call('GET', '/api/$key/lights');
      expect(seen, [key]);
    });

    test('removing an app goes through one path for the API and the settings screen', () {
      final key = pair('a#b');
      final before = changes;
      expect(api.removeUser(key), isTrue);
      expect(changes, before + 1);
      expect(api.removeUser(key), isFalse);
      expect(changes, before + 1);
      expect(errorOf(call('GET', '/api/$key/lights'))['type'], 1);
    });
  });

  group('full state and errors', () {
    test('GET /api/<key> returns every resource', () {
      final key = pair();
      final json = call('GET', '/api/$key') as Map;
      expect(json.keys, containsAll(['lights', 'groups', 'config', 'scenes', 'schedules', 'sensors', 'rules']));
      expect(json['resourcelinks'], isEmpty);
      expect(json['schedules'], isEmpty);
      expect((json['lights'] as Map).length, 4);
      expect(json['config']['whitelist'], contains(key));
    });

    test('an unknown resource is error type 3', () {
      final key = pair();
      expect(errorOf(call('GET', '/api/$key/teleporters'))['type'], 3);
      expect(errorOf(call('GET', '/api/$key/lights/99'))['type'], 3);
      expect(errorOf(call('PUT', '/api/$key/lights/99/state', {'on': true}))['type'], 3);
      expect(errorOf(call('GET', '/api/$key/groups/99'))['type'], 3);
    });

    test('a method a resource does not take is error type 4', () {
      final key = pair();
      final error = errorOf(call('DELETE', '/api/$key/lights'));
      expect(error['type'], 4);
      expect(error['description'], contains('DELETE'));
    });

    test('a path outside /api is a plain 404', () {
      final (status, _) = api.handle('GET', '/index.html', '');
      expect(status, 404);
    });
  });

  group('lights', () {
    test('every app light gets a numeric id, a type by kind and a state', () {
      final key = pair();
      final json = call('GET', '/api/$key/lights') as Map;
      expect(json.keys, ['1', '2', '3', '4']);
      expect([for (final l in json.values) l['name']], ['Desk', 'Hall', 'Sofa', 'Kitchen']);
      expect(json['1']['type'], 'Extended color light');
      expect(json['2']['type'], 'Dimmable light');
      expect(json['1']['manufacturername'], 'Lumen');
      expect(json['1']['manufacturername'], isNot(contains('Philips')));
      expect(json['1']['modelid'], isNotEmpty);
      expect(json['1']['uniqueid'], matches(RegExp(r'^([0-9a-f]{2}:){7}[0-9a-f]{2}-0b$')));
      expect(json['1']['uniqueid'], isNot(json['2']['uniqueid']));
      expect(json['1']['capabilities']['control']['colorgamuttype'], 'C');
      expect(json['1']['capabilities']['control']['ct'], {'min': 153, 'max': 500});
      expect(json['2']['capabilities']['control'].containsKey('ct'), isFalse);
    });

    test('an ambiance light is a Color temperature light', () async {
      central.addBulb(SimulatedHueBulb(id: 'cc', name: 'Lamp', model: 'LTA001'));
      final found = await home.scanBluetooth().firstWhere((b) => b.deviceId == 'cc');
      await home.addBluetoothLight(found);
      final key = pair();
      final json = call('GET', '/api/$key/lights/5') as Map;
      expect(json['type'], 'Color temperature light');
      expect(json['state']['colormode'], 'ct');
      expect(json['state'].containsKey('xy'), isFalse);
    });

    test('a colour light state has every v1 field', () {
      final key = pair();
      final state = (call('GET', '/api/$key/lights/1') as Map)['state'] as Map;
      expect(
        state.keys,
        containsAll(['on', 'bri', 'hue', 'sat', 'xy', 'ct', 'colormode', 'alert', 'effect', 'reachable', 'mode']),
      );
      expect(state['effect'], 'none');
      expect(state['mode'], 'homeautomation');
      expect(state['colormode'], 'ct');
      expect(state['ct'], 366);
      expect(state['reachable'], isTrue);
    });

    test('a white light state has no colour fields', () {
      final key = pair();
      final state = (call('GET', '/api/$key/lights/2') as Map)['state'] as Map;
      expect(state.keys, isNot(contains('xy')));
      expect(state.keys, isNot(contains('ct')));
      expect(state.keys, containsAll(['on', 'bri', 'alert', 'reachable', 'mode']));
    });

    test('ids stay the same across restarts and after a light is removed', () async {
      final key = pair();
      api = build();
      expect((call('GET', '/api/$key/lights') as Map).keys, ['1', '2', '3', '4']);
      await home.remove(desk);
      central.addBulb(SimulatedHueBulb(id: 'cc', name: 'Lamp'));
      final found = await home.scanBluetooth().firstWhere((b) => b.deviceId == 'cc');
      await home.addBluetoothLight(found);
      final json = call('GET', '/api/$key/lights') as Map;
      expect(json.keys, ['2', '3', '4', '5']);
      expect(json['5']['name'], 'Lamp');
      final restored = EmulatorSettings.fromJson(jsonDecode(jsonEncode(settings.toJson())) as Map<String, Object?>);
      expect(restored.lightIds, settings.lightIds);
    });

    test('PUT state with on and bri switches a Bluetooth bulb and answers like a bridge', () async {
      final key = pair();
      final json = call('PUT', '/api/$key/lights/1/state', {'on': true, 'bri': 100});
      expect(json, [
        {
          'success': {'/lights/1/state/on': true},
        },
        {
          'success': {'/lights/1/state/bri': 100},
        },
      ]);
      await until(() => central.bulbs['aa']!.state.on == true && central.bulbs['aa']!.state.brightness == 100);
    });

    test('bri_inc changes the brightness by a step and clamps', () async {
      final key = pair();
      call('PUT', '/api/$key/lights/3/state', {'bri': 200});
      await until(() => bridge.lights['1']!.state.brightness == 200);
      call('PUT', '/api/$key/lights/3/state', {'bri_inc': -50});
      await until(() => bridge.lights['1']!.state.brightness == 150);
      call('PUT', '/api/$key/lights/3/state', {'bri_inc': 254});
      await until(() => bridge.lights['1']!.state.brightness == 254);
    });

    test('xy, ct and transitiontime reach the light', () async {
      final key = pair();
      call('PUT', '/api/$key/lights/3/state', {
        'xy': [0.4, 0.5],
        'transitiontime': 8,
      });
      await until(() => bridge.lights['1']!.state.color == const XyColor(0.4, 0.5));
      expect(bridge.lastBody, containsPair('transitiontime', 8));
      call('PUT', '/api/$key/lights/3/state', {'ct': 250});
      await until(() => bridge.lights['1']!.state.color == const WhiteColor(250));
    });

    test('hue and sat become xy through the colour wheel maths', () async {
      final key = pair();
      call('PUT', '/api/$key/lights/3/state', {'hue': 21845, 'sat': 254});
      final expected = ColorMath.hueSatToXy(21845 / 65535 * 360, 1);
      await until(() => bridge.lights['1']!.state.color is XyColor);
      final got = bridge.lights['1']!.state.color as XyColor;
      expect(got.x, closeTo(expected.x, 1e-3));
      expect(got.y, closeTo(expected.y, 1e-3));
      final state = (call('GET', '/api/$key/lights/3') as Map)['state'] as Map;
      expect(state['colormode'], 'xy');
      expect((state['hue'] as int) / 65535 * 360, closeTo(120, 2));
    });

    test('hue alone keeps the current saturation', () async {
      final key = pair();
      call('PUT', '/api/$key/lights/3/state', {'hue': 0, 'sat': 127});
      await until(() => bridge.lights['1']!.state.color is XyColor);
      call('PUT', '/api/$key/lights/3/state', {'hue': 43690});
      final state = (call('GET', '/api/$key/lights/3') as Map)['state'] as Map;
      expect((state['sat'] as int), closeTo(127, 3));
      expect((state['hue'] as int) / 65535 * 360, closeTo(240, 2));
    });

    test('xy on a white light is error type 6 while the rest still applies', () async {
      final key = pair();
      final json = call('PUT', '/api/$key/lights/2/state', {
        'on': true,
        'xy': [0.4, 0.5],
      }) as List;
      expect(json.first, {
        'success': {'/lights/2/state/on': true},
      });
      expect((json.last as Map)['error']['type'], 6);
      await until(() => central.bulbs['bb']!.state.on == true);
    });

    test('an unknown parameter is error type 6 and a wrong type is error type 7', () {
      final key = pair();
      final json = call('PUT', '/api/$key/lights/1/state', {'sparkle': true, 'bri': 'high'}) as List;
      expect([for (final e in json) (e as Map)['error']['type']], [6, 7]);
    });

    test('alert select blinks the light', () async {
      final key = pair();
      final json = call('PUT', '/api/$key/lights/3/state', {'alert': 'select'});
      expect(json, [
        {
          'success': {'/lights/3/state/alert': 'select'},
        },
      ]);
      await until(() => bridge.alerts.contains('1'));
    });

    test('PUT /lights/<id> renames the light', () async {
      final key = pair();
      final json = call('PUT', '/api/$key/lights/1', {'name': 'Reading lamp'});
      expect(json, [
        {
          'success': {'/lights/1/name': 'Reading lamp'},
        },
      ]);
      await until(() => home.light(desk)!.name == 'Reading lamp');
    });

    test('lights the app gets from this emulator itself are not served again', () async {
      final own = EmulatorSettings(mac: 'aa:bb:cc:dd:ee:ff');
      expect(own.bridgeId, 'AABBCCFFFEDDEEFF');
      final selfBridge = SimulatedBridge(id: own.bridgeId.toLowerCase())..addLight(SimulatedBridgeLight(name: 'Echo'));
      final loop = HomeController(AppServices.simulated(bridge: selfBridge, store: MemoryHomeStore()));
      await loop.load();
      selfBridge.pressLinkButton();
      await loop.pairBridge('10.0.0.9', interval: const Duration(milliseconds: 5));
      expect(loop.lights, hasLength(1));
      final loopApi = BridgeApi(loop, own, clock: () => now);
      loopApi.pressLinkButton();
      final key =
          (((loopApi.handle('POST', '/api', '{"devicetype":"a#b"}').$2 as List).single as Map)['success']
                  as Map)['username']
              as String;
      expect(loopApi.handle('GET', '/api/$key/lights', '').$2, isEmpty);
      loop.dispose();
    });
  });

  group('groups', () {
    late String roomKey;

    setUp(() async {
      // Start from no rooms: pairing imported the real bridge's Lounge.
      for (final r in home.rooms) {
        await home.deleteRoom(r.id);
      }
      await home.createRoom('Study', [desk, hall]);
      await home.createRoom('Lounge', [sofa, kitchen]);
      roomKey = pair();
    });

    test('GET /groups lists rooms as type Room with numeric ids', () {
      final json = call('GET', '/api/$roomKey/groups') as Map;
      expect(json.keys, ['1', '2']);
      expect(json['1']['name'], 'Study');
      expect(json['1']['type'], 'Room');
      expect(json['1']['lights'], ['1', '2']);
      expect(json['2']['lights'], ['3', '4']);
      expect(json['1']['state'], {'all_on': false, 'any_on': false});
      expect(json['1']['action'], contains('on'));
    });

    test('GET /groups/0 is every light', () {
      final json = call('GET', '/api/$roomKey/groups/0') as Map;
      expect(json['type'], 'LightGroup');
      expect(json['lights'], ['1', '2', '3', '4']);
      expect((call('GET', '/api/$roomKey/groups/2') as Map)['name'], 'Lounge');
    });

    test('PUT /groups/<id>/action switches the room\'s bulbs', () async {
      final json = call('PUT', '/api/$roomKey/groups/1/action', {'on': true});
      expect(json, [
        {
          'success': {'/groups/1/action/on': true},
        },
      ]);
      await until(() => central.bulbs['aa']!.state.on == true && central.bulbs['bb']!.state.on == true);
      final state = (call('GET', '/api/$roomKey/groups/1') as Map)['state'];
      expect(state, {'all_on': true, 'any_on': true});
    });

    test('a room of bridge lights goes out as one bridge group action, like the app does', () async {
      bridge.requests.clear();
      call('PUT', '/api/$roomKey/groups/2/action', {'on': true, 'bri': 90});
      await until(() => bridge.lights.values.every((l) => l.state.on == true && l.state.brightness == 90));
      expect(bridge.requests, hasLength(1));
      expect(bridge.requests.single, matches(RegExp(r'^PUT /groups/\d+/action$')));
    });

    test('a colour sent to a room is adapted for its white bulb', () async {
      call('PUT', '/api/$roomKey/groups/1/action', {
        'on': true,
        'xy': [0.6, 0.35],
      });
      await until(() => central.bulbs['aa']!.state.color is XyColor && central.bulbs['bb']!.state.on == true);
    });

    test('a scene applies through a group action', () async {
      final json = call('PUT', '/api/$roomKey/groups/0/action', {'scene': 'starter-read'});
      expect(json, [
        {
          'success': {'/groups/0/action/scene': 'starter-read'},
        },
      ]);
      await until(() => bridge.lights['1']!.state.color == const WhiteColor(346));
      await until(() => central.bulbs['bb']!.state.on == true);
    });

    test('a preset applied to a room touches only that room', () async {
      call('PUT', '/api/$roomKey/groups/2/action', {'scene': 'starter-concentrate'});
      await until(() => bridge.lights.values.every((l) => l.state.color == const WhiteColor(233)));
      expect(central.bulbs['aa']!.state.on, isFalse);
    });

    test('an unknown scene is error type 7', () {
      expect(errorOf(call('PUT', '/api/$roomKey/groups/1/action', {'scene': 'nope'}))['type'], 7);
    });

    test('room ids stay put when a room before them is deleted', () async {
      expect((call('GET', '/api/$roomKey/groups') as Map).keys, ['1', '2']);
      await home.deleteRoom(home.rooms.first.id);
      final json = call('GET', '/api/$roomKey/groups') as Map;
      expect(json.keys, ['2']);
    });
  });

  group('scenes', () {
    test('GET /scenes lists the app\'s profiles', () async {
      await home.saveScene('Evening', [sofa, kitchen]);
      final key = pair();
      final json = call('GET', '/api/$key/scenes') as Map;
      expect(json['starter-relax']['name'], 'Relax');
      expect(json['starter-relax']['type'], 'LightScene');
      expect(json['starter-relax']['lights'], ['1', '2', '3', '4']);
      final evening = json.entries.firstWhere((e) => e.value['name'] == 'Evening');
      expect(evening.value['lights'], ['3', '4']);
    });

    test('GET /scenes/<id> includes the light states', () {
      final key = pair();
      final json = call('GET', '/api/$key/scenes/starter-read') as Map;
      expect(json['lightstates']['3'], containsPair('ct', 346));
      expect(json['lightstates']['3'], containsPair('bri', 254));
      expect(errorOf(call('GET', '/api/$key/scenes/nope'))['type'], 3);
    });
  });

  group('edge cases', () {
    List<Object?> errorTypes(Object? json) => [for (final e in json as List) ((e as Map)['error'] as Map?)?['type']];

    test('GET /api with no key is a method error, as on a bridge', () {
      final error = errorOf(call('GET', '/api'));
      expect(error['type'], 4);
      expect(error['description'], 'method, GET, not available for resource, /');
    });

    test('the resources it does not model read as empty', () {
      final key = pair();
      for (final resource in ['schedules', 'sensors', 'rules', 'resourcelinks']) {
        expect(call('GET', '/api/$key/$resource'), isEmpty, reason: resource);
      }
    });

    test('a method a group or scene does not take is error 4, and a missing one error 3', () {
      final key = pair();
      expect(errorOf(call('DELETE', '/api/$key/groups/0'))['type'], 4);
      expect(errorOf(call('DELETE', '/api/$key/groups/99'))['type'], 3);
      expect(errorOf(call('PUT', '/api/$key/scenes/starter-read', {'name': 'x'}))['type'], 4);
      expect(errorOf(call('DELETE', '/api/$key/lights/1'))['type'], 4);
    });

    test('revoking an app that is not paired is error 3 and saves nothing', () {
      final key = pair();
      changes = 0;
      expect(errorOf(call('DELETE', '/api/$key/config/whitelist/ghost'))['type'], 3);
      expect(changes, 0);
    });

    test('PUT config with linkbutton true opens the pairing window', () {
      final key = pair();
      now = now.add(const Duration(minutes: 5));
      expect(api.linkButtonActive, isFalse);
      final json = call('PUT', '/api/$key/config', {'linkbutton': true});
      expect(json, [
        {
          'success': {'/config/linkbutton': true},
        },
      ]);
      expect(api.linkButtonActive, isTrue);
    });

    test('PUT config refuses bad values and parameters it does not have, and keeps the name', () {
      final key = pair();
      final json = call('PUT', '/api/$key/config', {'name': '  ', 'linkbutton': false, 'zigbeechannel': 11});
      expect(errorTypes(json), [7, 7, 6]);
      expect(((json as List)[2] as Map)['error']['address'], '/config/zigbeechannel');
      expect(settings.name, 'Lumen');
      expect(errorOf(call('PUT', '/api/$key/config', {'name': 'x' * 33}))['type'], 7);
      expect(errorOf(call('PUT', '/api/$key/config', ['name']))['type'], 5);
    });

    test('PUT lights/<id> refuses a bad name and other parameters, and keeps the name', () async {
      final key = pair();
      final json = call('PUT', '/api/$key/lights/1', {'name': '', 'archetype': 'spot'});
      expect(errorTypes(json), [7, 6]);
      expect(errorOf(call('PUT', '/api/$key/lights/1', 'Desk 2'))['type'], 5);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(home.light(desk)!.name, 'Desk');
    });

    test('a state value out of range or of the wrong shape is error 7, and nothing changes', () async {
      final key = pair();
      bridge.requests.clear();
      final json = call('PUT', '/api/$key/lights/3/state', {
        'bri_inc': 255,
        'xy': [1.5, 0.2],
        'hue': 65536,
        'sat': -1,
        'transitiontime': -1,
        'alert': 'blink',
        'effect': 'colorloop',
        'ct': 'warm',
      });
      expect(errorTypes(json), [7, 7, 7, 7, 7, 7, 7, 7]);
      expect(errorOf(call('PUT', '/api/$key/lights/3/state', 'on'))['type'], 5);
      expect(errorTypes(call('PUT', '/api/$key/lights/3/state', {'xy': 'red'})), [7]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bridge.requests, isEmpty);
    });

    test('effect none and alert none are accepted and send nothing', () async {
      final key = pair();
      bridge.requests.clear();
      final json = call('PUT', '/api/$key/lights/3/state', {'effect': 'none', 'alert': 'none'});
      expect(json, [
        {
          'success': {'/lights/3/state/effect': 'none'},
        },
        {
          'success': {'/lights/3/state/alert': 'none'},
        },
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bridge.requests, isEmpty);
      expect(bridge.alerts, isEmpty);
    });

    test('a room with no lights has an off action and is neither all nor any on', () async {
      await home.createRoom('Attic', []);
      final key = pair();
      final groups = call('GET', '/api/$key/groups') as Map;
      final attic = groups.values.firstWhere((g) => g['name'] == 'Attic') as Map;
      expect(attic['lights'], isEmpty);
      expect(attic['state'], {'all_on': false, 'any_on': false});
      expect(attic['action'], {'on': false, 'bri': 254, 'alert': 'none'});
    });

    test('a plug and a colour light that reports no colour are served the way a bridge would', () async {
      final plugs = SimulatedBridge(id: '001788fffe000002')
        ..addLight(SimulatedBridgeLight(name: 'Kettle', type: 'On/Off plug-in unit'))
        ..addLight(
          SimulatedBridgeLight(name: 'Bare', reachable: false, state: const LightState(on: true, brightness: 10)),
        );
      final other = HomeController(AppServices.simulated(bridge: plugs, store: MemoryHomeStore()));
      addTearDown(other.dispose);
      await other.load();
      plugs.pressLinkButton();
      await other.pairBridge('10.0.0.8', interval: const Duration(milliseconds: 5));
      final otherApi = BridgeApi(other, EmulatorSettings(mac: '02:00:00:00:00:01'), clock: () => now);
      otherApi.pressLinkButton();
      final key =
          (((otherApi.handle('POST', '/api', '{"devicetype":"a#b"}').$2 as List).single as Map)['success']
                  as Map)['username']
              as String;
      final lights = jsonDecode(jsonEncode(otherApi.handle('GET', '/api/$key/lights', '').$2)) as Map;
      final kettle = lights.values.firstWhere((l) => l['name'] == 'Kettle') as Map;
      expect(kettle['type'], 'On/Off plug-in unit');
      expect(kettle['modelid'], 'LOM001');
      expect(kettle['productname'], 'Lumen on/off light');
      expect(kettle['state'].keys, isNot(contains('xy')));
      expect(kettle['state'].keys, isNot(contains('ct')));
      final bare = lights.values.firstWhere((l) => l['name'] == 'Bare') as Map;
      final state = bare['state'] as Map;
      expect(state['reachable'], isFalse);
      // No colour reads as the default warm white the app starts bulbs at.
      final warm = ColorMath.rgbToXy(ColorMath.miredsToRgb(366));
      expect(state['xy'][0], closeTo(warm.x, 1e-4));
      expect(state['xy'][1], closeTo(warm.y, 1e-4));
      expect(state['ct'], 366);
      expect(state['colormode'], 'ct');
    });
  });
}
