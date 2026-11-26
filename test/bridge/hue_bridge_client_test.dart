import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:lumen/domain/errors.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/log/logger.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/transport/bridge/hue_bridge_client.dart';

import 'self_signed_certificate.dart';

void main() {
  late SimulatedBridge bridge;
  late HttpServer server;
  late HueBridgeClient client;

  setUp(() async {
    bridge = SimulatedBridge(id: '001788fffe123456', name: 'Living bridge')
      ..addLight(SimulatedBridgeLight(name: 'Sofa', type: 'Extended color light'))
      ..addLight(SimulatedBridgeLight(name: 'Hall', type: 'Dimmable light'));
    server = await bridge.serve();
    client = HueBridgeClient(http.Client(), Uri.parse('http://127.0.0.1:${server.port}'));
  });

  tearDown(() => server.close(force: true));

  test('reads the bridge name and id without a key', () async {
    final config = await client.config();
    expect(config.name, 'Living bridge');
    expect(config.id, '001788fffe123456');
  });

  test('pairing before the link button is pressed fails with LinkButtonNotPressed', () async {
    await expectLater(client.pair(), throwsA(isA<LinkButtonNotPressed>()));
  });

  test('pairing after the link button is pressed returns an app key', () async {
    bridge.pressLinkButton();
    final key = await client.pair();
    expect(bridge.appKeys, contains(key));
  });

  test('waitForLinkButton polls until the button is pressed', () async {
    Future<void>.delayed(const Duration(milliseconds: 120), bridge.pressLinkButton);
    final key = await client.waitForLinkButton(interval: const Duration(milliseconds: 40));
    expect(bridge.appKeys, contains(key));
  });

  test('waitForLinkButton gives up after the timeout', () async {
    await expectLater(
      client.waitForLinkButton(interval: const Duration(milliseconds: 20), timeout: const Duration(milliseconds: 100)),
      throwsA(isA<LinkButtonNotPressed>()),
    );
  });

  test('lists lights with kind and state', () async {
    bridge.pressLinkButton();
    final key = await client.pair();
    final lights = await client.lights(key);
    expect(lights.map((l) => l.name), ['Sofa', 'Hall']);
    expect(lights.first.kind, LightKind.color);
    expect(lights.last.kind, LightKind.white);
    expect(lights.first.reachable, isTrue);
  });

  test('setState sends on, bri, xy and transition time', () async {
    bridge.pressLinkButton();
    final key = await client.pair();
    await client.setState(
      key,
      '1',
      const LightCommand(on: true, brightness: 120, color: XyColor(0.4, 0.5), transition: Duration(milliseconds: 800)),
    );
    final sofa = bridge.lights['1']!;
    expect(sofa.state.on, isTrue);
    expect(sofa.state.brightness, 120);
    expect(sofa.state.color, const XyColor(0.4, 0.5));
    expect(bridge.lastBody, containsPair('transitiontime', 8));
  });

  test('an unknown key raises BridgeUnauthorized', () async {
    await expectLater(client.lights('nope'), throwsA(isA<BridgeUnauthorized>()));
  });

  test('an unreachable bridge raises BridgeUnreachable, and says it is offline', () async {
    await server.close(force: true);
    await expectLater(client.config(), throwsA(isA<BridgeOffline>()));
  });

  test('a bridge that answers with an error is not offline', () async {
    bridge.pressLinkButton();
    final key = await client.pair();
    bridge.failAll = true;
    await expectLater(client.lights(key), throwsA(allOf(isA<BridgeUnreachable>(), isNot(isA<BridgeOffline>()))));
  });

  test('a bare address means a real bridge over HTTPS', () {
    expect(HueBridgeClient.forHost('192.168.1.20').base, Uri.parse('https://192.168.1.20'));
    expect(HueBridgeClient.forHost(' bridge.local ').base, Uri.parse('https://bridge.local'));
  });

  test('an address with a port means an emulated bridge over plain HTTP', () {
    expect(HueBridgeClient.forHost('192.168.1.20:1818').base, Uri.parse('http://192.168.1.20:1818'));
    expect(HueBridgeClient.forHost('lumen.local:80').base, Uri.parse('http://lumen.local:80'));
  });

  test('forHost with a port talks to a plain HTTP bridge', () async {
    final real = HueBridgeClient.forHost('127.0.0.1:${server.port}');
    final config = await real.config();
    expect(config.name, 'Living bridge');
  });

  test('logs each call with method, redacted path, status, size and time', () async {
    final log = Logger.memory()..debugEnabled = true;
    final logged = HueBridgeClient(http.Client(), Uri.parse('http://127.0.0.1:${server.port}'), log: log);
    bridge.pressLinkButton();
    final key = await logged.pair();
    await logged.lights(key);
    final text = log.entries.map((e) => e.message).join('\n');
    expect(text, contains('POST /api 200'));
    expect(text, contains('GET /api/${key.substring(0, 4)}.../lights 200'));
    expect(text, isNot(contains(key)));
    expect(text, contains(' bytes'));
    expect(text, contains(' ms'));
  });

  test('logs a failed call as a warning', () async {
    final log = Logger.memory();
    final port = server.port;
    await server.close(force: true);
    final logged = HueBridgeClient(http.Client(), Uri.parse('http://127.0.0.1:$port'), log: log);
    await expectLater(logged.config(), throwsA(isA<BridgeUnreachable>()));
    expect(log.entries.single.level, LogLevel.warning);
    expect(log.entries.single.message, contains('GET /api/config failed'));
  });

  test('maps bridge light types to kinds, including on/off plugs', () {
    expect(HueBridgeClient.kindForType('Extended color light'), LightKind.color);
    expect(HueBridgeClient.kindForType('Color temperature light'), LightKind.ambiance);
    expect(HueBridgeClient.kindForType('Dimmable light'), LightKind.white);
    expect(HueBridgeClient.kindForType('On/Off plug-in unit'), LightKind.onOff);
  });

  group('over HTTPS with a certificate no device trusts', () {
    late HttpServer secure;
    late Uri base;

    setUp(() async {
      secure = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, selfSignedContext());
      secure.listen((request) async {
        final (status, json) = bridge.handle(request.method, request.uri.path, await utf8.decodeStream(request));
        request.response
          ..statusCode = status
          ..write(jsonEncode(json));
        await request.response.close();
      });
      base = Uri.parse('https://127.0.0.1:${secure.port}');
    });

    tearDown(() => secure.close(force: true));

    test('the client for a bridge accepts its certificate', () async {
      final trusting = HueBridgeClient(IOClient(HueBridgeClient.httpClientFor('127.0.0.1')), base);
      expect((await trusting.config()).name, 'Living bridge');
    });

    test('a default client refuses it', () async {
      final strict = HueBridgeClient(http.Client(), base);
      await expectLater(strict.config(), throwsA(isA<BridgeUnreachable>()));
    });

    test('the client for one bridge refuses the certificate of another host', () async {
      final other = HueBridgeClient(IOClient(HueBridgeClient.httpClientFor('192.168.1.20')), base);
      await expectLater(other.config(), throwsA(isA<BridgeUnreachable>()));
    });
  });

  group('answers in other shapes', () {
    HueBridgeClient answering(Object? json, {int status = 200}) =>
        HueBridgeClient(MockClient((_) async => http.Response(jsonEncode(json), status)), Uri.parse('http://bridge'));

    test('a light reads ct outside ct mode, and no colour or state at all', () async {
      final lights = await answering({
        '1': {
          'name': 'Hue mode',
          'type': 'Extended color light',
          'state': {'on': true, 'bri': 7, 'colormode': 'hs', 'ct': 300, 'reachable': false},
        },
        '2': {'type': 'Dimmable light'},
        'junk': 'not a light',
      }).lights('key');
      expect(lights, hasLength(2));
      expect(lights.first.state.color, const WhiteColor(300));
      expect(lights.first.state.brightness, 7);
      expect(lights.first.reachable, isFalse);
      expect(lights.last.name, 'Light 2');
      expect(lights.last.state.color, isNull);
      expect(lights.last.state.on, isNull);
      expect(lights.last.reachable, isTrue);
    });

    test('an error the app has no name for carries the bridge\'s description', () async {
      final client = answering([
        {
          'error': {'type': 7, 'address': '/lights/1/state/bri', 'description': 'invalid value'},
        },
      ]);
      await expectLater(
        client.setState('key', '1', const LightCommand(brightness: 9)),
        throwsA(isA<BridgeUnreachable>().having((e) => e.message, 'message', 'The bridge said: invalid value')),
      );
    });
  });
}
