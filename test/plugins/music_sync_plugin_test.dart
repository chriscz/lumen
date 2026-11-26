// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/emulator/bridge_api.dart';
import 'package:lumen/emulator/bridge_extensions.dart';
import 'package:lumen/emulator/emulator_settings.dart';
import 'package:lumen/music/music_settings.dart';
import 'package:lumen/music/music_sync.dart';
import 'package:lumen/plugins/music_sync_plugin.dart';
import 'package:lumen/plugins/plugin_manager.dart';
import 'package:lumen/sim/simulated_audio.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/bridge/hue_bridge_client.dart';

void main() {
  const key = 'app-key';
  const before = LightState(on: true, brightness: 100, color: XyColor(0.3, 0.3));
  late SimulatedBleCentral central;
  late HomeController home;
  late PluginManager plugins;
  late MusicSyncPlugin plugin;
  late BridgeApi api;
  late SimulatedAudioInput audio;

  /// A phone with the Desk bulb, music sync as a plugin, and the emulated
  /// bridge's API with an app paired.
  void run(void Function(FakeAsync async) body, {bool withBulb = true}) => fakeAsync((async) {
    central = SimulatedBleCentral(scanDelay: Duration.zero);
    if (withBulb) central.addBulb(SimulatedHueBulb(id: 'aa', name: 'Desk', state: before));
    home = HomeController(AppServices.simulated(central: central, audio: audio = SimulatedAudioInput()));
    home.load();
    async.flushMicrotasks();
    if (withBulb) {
      home.scanBluetooth().firstWhere((b) => b.deviceId == 'aa').then(home.addBluetoothLight);
      async.elapse(const Duration(seconds: 2));
    }
    plugin = MusicSyncPlugin();
    plugins = PluginManager(home, plugins: [plugin])..load();
    async.flushMicrotasks();
    final settings = EmulatorSettings(mac: 'aa:bb:cc:dd:ee:ff')
      ..users[key] = PairedApp(username: key, devicetype: 'test#lumen', created: DateTime.utc(2026));
    api = BridgeApi(home, settings, extensions: plugins.bridge);
    body(async);
    plugins.dispose();
    async.elapse(const Duration(seconds: 1));
  });

  const base = '/__plugins__/music-sync/v1.0.0';

  (int, Map<String, Object?>) call(String method, String path, [Object? body]) {
    final (status, json) = api.handle(
      method,
      '$base$path',
      body == null ? '' : jsonEncode(body),
      headers: const {'hue-application-key': key},
    );
    return (status, (json as Map).cast<String, Object?>());
  }

  /// The links of [body], as rel to href and method.
  Map<String, (Object?, Object?)> links(Map<String, Object?> body) => {
    for (final MapEntry(:key, :value) in (body['links'] as Map).entries)
      key as String: ((value as Map)['href'], value['method']),
  };

  test('is an experimental plugin that is on by default', () {
    run((async) {
      expect(plugin.id, 'music-sync');
      expect(plugin.experimental, isTrue);
      expect(plugins.isEnabled('music-sync'), isTrue);
      expect(plugin.music, isNotNull);
      expect(plugin.music!.loaded, isTrue);
    });
  });

  test('switching it off stops music sync and puts the lights back', () {
    run((async) {
      plugin.music!.start();
      async.elapse(const Duration(seconds: 8));
      expect(plugin.music!.phase, MusicSyncPhase.following);
      plugins.setEnabled('music-sync', false);
      async.elapse(const Duration(seconds: 1));
      expect(plugin.music, isNull);
      expect(central.bulbs['aa']!.state.brightness, 100);
      expect(call('GET', '/').$1, 404);
    });
  });

  test('the bridge API reports the status, sources and rooms', () {
    run((async) {
      home.createRoom('Den', [home.lights.single.id]);
      async.flushMicrotasks();
      final (status, body) = call('GET', '/');
      expect(status, 200);
      expect(body['phase'], 'off');
      expect(links(body), {
        'self': ('$base/', null),
        'settings': ('$base/settings', 'PUT'),
        'start': ('$base/start', 'POST'),
        'plugin': ('/__plugins__/music-sync', null),
      });
      expect(body['bpm'], isNull);
      expect(body['settings'], containsPair('source', 'microphone'));
      expect(body['sources'], containsPair('capture', {'state': 'ready', 'reason': null}));
      expect(body['rooms'], [
        {'id': home.rooms.single.id, 'name': 'Den'},
      ]);
      expect(body['lights'], 1);
    });
  });

  test('v1.0.0 settings show only what v1.0.0 had', () {
    run((async) {
      plugin.music!.update(plugin.music!.settings.copyWith(trackingLog: true));
      async.flushMicrotasks();
      final (status, body) = call('GET', '/');
      expect(status, 200);
      expect((body['settings'] as Map).keys, isNot(anyElement(isIn(['trackingLog', 'follow', 'sensitivity', 'steadiness']))));
      final (_, put) = call('PUT', '/settings', {'style': 'glow'});
      expect((put['settings'] as Map).containsKey('trackingLog'), isFalse);
      expect(plugin.music!.settings.trackingLog, isTrue, reason: 'a remote change keeps it');
    });
  });

  test('v1.0.0 reports holding as following and breathing as listening', () {
    run((async) {
      call('POST', '/start');
      async.elapse(const Duration(seconds: 7));
      expect(plugin.music!.phase, MusicSyncPhase.following);
      audio.muted = true;
      for (var i = 0; i < 100 && plugin.music!.phase == MusicSyncPhase.following; i++) {
        async.elapse(const Duration(milliseconds: 100));
      }
      expect(plugin.music!.phase, MusicSyncPhase.holding);
      expect(call('GET', '/').$2['phase'], 'following');
      async.elapse(const Duration(seconds: 5));
      expect(plugin.music!.phase, MusicSyncPhase.breathing);
      expect(call('GET', '/').$2['phase'], 'listening');
    });
  });

  test('the bridge API starts and stops music sync, and follows the beat', () {
    run((async) {
      final (started, body) = call('POST', '/start');
      expect(started, 202);
      expect(body['phase'], isIn(['starting', 'listening']));
      expect(links(body), contains('stop'), reason: 'running, it offers stop');
      expect(links(body), isNot(contains('start')));
      async.elapse(const Duration(seconds: 8));
      final (_, now) = call('GET', '/');
      expect(now['phase'], 'following');
      expect(now['bpm'] as double, closeTo(120, 1.5));
      expect(now['beats'] as int, greaterThan(3));
      expect(call('POST', '/stop').$1, 200);
      async.elapse(const Duration(seconds: 1));
      expect(call('GET', '/').$2['phase'], 'off');
      expect(central.bulbs['aa']!.state.brightness, 100);
    });
  });

  test('the bridge API changes settings, and refuses what it does not know', () {
    run((async) {
      final (ok, answer) = call('PUT', '/settings', {'style': 'glow', 'strength': 0.25, 'timingMs': -60});
      expect(ok, 200);
      expect(answer['settings'], containsPair('style', 'glow'));
      expect(links(answer)['status'], ('$base/', null));
      async.flushMicrotasks();
      expect(plugin.music!.settings.style, MusicStyle.glow);
      expect(plugin.music!.settings.strength, 0.25);
      expect(plugin.music!.settings.timing, const Duration(milliseconds: -60));

      expect(call('PUT', '/settings', {'style': 'disco'}).$1, 400);
      expect(call('PUT', '/settings', {'colour': 'red'}).$1, 400);
      expect(call('PUT', '/settings', {'roomId': 'no-such-room'}).$1, 400);
      expect(call('PUT', '/settings', ['style']).$1, 400);
      expect(call('DELETE', '/settings').$1, 405);
      expect(call('GET', '/nothing').$1, 404);
    });
  });

  test('starting over the bridge with no lights is a conflict', () {
    run((async) {
      final (status, body) = call('POST', '/start');
      expect(status, 409);
      expect((body['error'] as Map)['type'], 'conflict');
    }, withBulb: false);
  });

  test("works over Lumen's own bridge: a second phone's music moves the first phone's bulb", () {
    run((async) {
      // Phone B pairs with phone A's emulated bridge, in process.
      final toA = MockClient((request) async {
        final (status, json) = api.handle(request.method, request.url.path, request.body);
        return http.Response(jsonEncode(json), status, headers: {'content-type': 'application/json'});
      });
      final phoneB = HomeController(
        AppServices(
          central: SimulatedBleCentral(),
          bridgeClient: (host) => HueBridgeClient(toA, Uri.parse('http://$host')),
          store: MemoryHomeStore(),
          audio: SimulatedAudioInput(),
        ),
      );
      phoneB.load();
      async.flushMicrotasks();
      api.pressLinkButton();
      phoneB.pairBridge('192.168.1.20:1818', interval: Duration.zero);
      async.elapse(const Duration(seconds: 1));
      expect(phoneB.lights.single.transport, Transport.bridge);

      final music = MusicSync(phoneB)..load();
      async.flushMicrotasks();
      music.start();
      async.elapse(const Duration(seconds: 7));
      var flashes = 0;
      var was = false;
      for (var i = 0; i < 400; i++) {
        async.elapse(const Duration(milliseconds: 5));
        final full = central.bulbs['aa']!.state.brightness == HueRange.maxBrightness;
        if (full && !was) flashes++;
        was = full;
      }
      expect(flashes, inInclusiveRange(3, 5), reason: 'about two a second for 2 s');
      music.dispose();
      async.elapse(const Duration(seconds: 1));
      expect(central.bulbs['aa']!.state.brightness, 100);
      phoneB.dispose();
    });
  });

  test('a request that reaches music sync while it is off is told so', () {
    run((async) {
      plugins.setEnabled('music-sync', false);
      async.flushMicrotasks();
      final handler = plugin.bridgeApi['1.0.0']!;
      final (status, _) = handler(const ExtensionRequest(method: 'GET', path: [], appKey: key, base: base));
      expect(status, 503);
    });
  });
}
