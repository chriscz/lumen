// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../domain/light.dart';
import '../transport/bridge/hue_bridge_client.dart';
import '../transport/bridge/hue_v1_state.dart';

class SimulatedBridgeLight {
  SimulatedBridgeLight({
    required this.name,
    this.type = 'Extended color light',
    this.reachable = true,
    this.state = const LightState(on: false, brightness: 254, color: WhiteColor(HueRange.defaultMireds)),
  });

  String name;
  final String type;
  bool reachable;
  LightState state;

  LightKind get kind => HueBridgeClient.kindForType(type);
}

/// A Hue Bridge that answers the parts of the v1 API the app uses. It can
/// run in process behind an [http.Client], or as a real HTTP server.
class SimulatedBridge {
  SimulatedBridge({
    this.id = '001788fffe000001',
    this.name = 'Hue Bridge',
    this.linkWindow = const Duration(seconds: 30),
    this.latency = Duration.zero,
  });

  final String id;
  final String name;
  final Duration linkWindow;
  final Duration latency;
  final Map<String, SimulatedBridgeLight> lights = {};
  final Set<String> appKeys = {};
  final List<String> alerts = [];
  DateTime? _linkPressedAt;
  Map<String, Object?>? lastBody;

  /// Every request after pairing, as `METHOD /path` without the app key.
  final List<String> requests = [];

  /// Makes every authorised request fail, as when the bridge goes offline.
  bool failAll = false;

  /// Makes the in-process client fail to connect at all, as when the bridge
  /// drops off the network.
  bool offline = false;

  /// Makes group actions fail while single-light calls still work.
  bool failGroups = false;
  final _random = Random(7);

  bool get linkButtonActive => _linkPressedAt != null && DateTime.now().difference(_linkPressedAt!) < linkWindow;

  void pressLinkButton() => _linkPressedAt = DateTime.now();

  SimulatedBridgeLight addLight(SimulatedBridgeLight light) => lights['${lights.length + 1}'] = light;

  /// Rooms as the bridge keeps them: id to name and light ids.
  final Map<String, (String, List<String>)> groups = {};

  void addGroup(String name, List<String> lightIds) => groups['${groups.length + 1}'] = (name, lightIds);

  /// An in-process client, used by widget tests and the demo mode.
  http.Client client() => MockClient((request) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (offline) throw http.ClientException('no route to host', request.url);
    final (status, body) = handle(request.method, request.url.path, request.body);
    return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
  });

  /// A real HTTP server on the loopback interface, for client tests.
  Future<HttpServer> serve() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decodeStream(request);
      final (status, json) = handle(request.method, request.uri.path, body);
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(json));
      await request.response.close();
    });
    return server;
  }

  (int, Object) handle(String method, String path, String rawBody) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    final body = rawBody.isEmpty ? null : jsonDecode(rawBody);
    if (body is Map) lastBody = body.cast<String, Object?>();
    if (segments.isEmpty || segments.first != 'api') return (404, {'error': 'not found'});

    switch ((method, segments.skip(1).toList())) {
      case ('GET', ['config']):
        return (200, {'name': name, 'bridgeid': id.toUpperCase(), 'modelid': 'BSB002'});
      case ('POST', []):
        if (!linkButtonActive) {
          return (200, [_error(101, '', 'link button not pressed')]);
        }
        final key = List.generate(40, (_) => _random.nextInt(36).toRadixString(36)).join();
        appKeys.add(key);
        return (
          200,
          [
            {
              'success': {'username': key},
            },
          ],
        );
      case (_, [final key, ...]) when !appKeys.contains(key):
        return (200, [_error(1, '/', 'unauthorized user')]);
      case (_, [_, ...final rest]) when failAll:
        return (503, {'error': 'unavailable ${rest.join('/')}'});
      case ('PUT', [_, 'groups', final groupId, 'action']):
        requests.add('PUT /groups/$groupId/action');
        if (failGroups) return (500, {'error': 'group failed'});
        final members = groupId == '0' ? lights.keys.toList() : groups[groupId]?.$2;
        if (members == null) return (200, [_error(3, '/groups/$groupId', 'resource not available')]);
        final b = (body as Map).cast<String, Object?>();
        for (final id in members) {
          _applyState(lights[id]!, b);
        }
        return (
          200,
          [
            for (final k in b.keys)
              {
                'success': {'/groups/$groupId/action/$k': b[k]},
              },
          ],
        );
      case ('GET', [_, 'groups']):
        return (
          200,
          {
            for (final MapEntry(key: id, value: (name, ids)) in groups.entries)
              id: {'name': name, 'type': 'Room', 'class': 'Living room', 'lights': ids},
          },
        );
      case ('GET', [_, 'lights']):
        return (200, {for (final e in lights.entries) e.key: _lightJson(e.value)});
      case ('PUT', [_, 'lights', final lightId, 'state']):
        requests.add('PUT /lights/$lightId/state');
        final light = lights[lightId];
        if (light == null) return (200, [_error(3, '/lights/$lightId', 'resource not available')]);
        final b = (body as Map).cast<String, Object?>();
        if (b['alert'] == 'select') alerts.add(lightId);
        _applyState(light, b);
        return (
          200,
          [
            for (final k in b.keys)
              {
                'success': {'/lights/$lightId/state/$k': b[k]},
              },
          ],
        );
    }
    return (404, [_error(4, path, 'method not available')]);
  }

  static void _applyState(SimulatedBridgeLight light, Map<String, Object?> b) {
    final kind = light.kind;
    light.state = light.state.apply(
      HueV1State.stateOf(b, honourColormode: false, acceptXy: kind.hasColor, acceptCt: kind.hasTemperature).toCommand(),
    );
  }

  static Map<String, Object> _error(int type, String address, String description) => {
    'error': {'type': type, 'address': address, 'description': description},
  };

  static Map<String, Object?> _lightJson(SimulatedBridgeLight l) => {
    'name': l.name,
    'type': l.type,
    'modelid': l.kind.hasColor ? 'LCT015' : 'LWB010',
    'state': {
      'on': l.state.on ?? false,
      'bri': l.state.brightness ?? 254,
      'reachable': l.reachable,
      ...HueV1State.colorJson(l.state.color, clampCt: false, round: false, colormode: true),
    },
  };
}
