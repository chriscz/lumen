// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/emulator/bridge_api.dart';
import 'package:lumen/emulator/bridge_extensions.dart';
import 'package:lumen/emulator/emulator_settings.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';

void main() {
  late HomeController home;
  late BridgeExtensions extensions;
  late BridgeApi api;
  final seen = <ExtensionRequest>[];
  const key = 'app-key';
  const paired = {'hue-application-key': key};

  setUp(() async {
    home = HomeController(AppServices.simulated());
    await home.load();
    extensions = BridgeExtensions();
    final settings = EmulatorSettings(mac: 'aa:bb:cc:dd:ee:ff')
      ..users[key] = PairedApp(username: key, devicetype: 'test#lumen', created: DateTime.utc(2026));
    api = BridgeApi(home, settings, extensions: extensions);
    seen.clear();
  });

  tearDown(() => home.dispose());

  (int, Map<String, Object?>) call(String method, String path, {Object? body, Map<String, String> headers = paired}) {
    final (status, json) = api.handle(method, path, body == null ? '' : jsonEncode(body), headers: headers);
    return (status, (json as Map).cast<String, Object?>());
  }

  (int, Object) echo(ExtensionRequest r) {
    seen.add(r);
    return (200, {'path': r.path, 'method': r.method, 'root': r.href(), 'settings': r.href('settings')});
  }

  Object? link(Map<String, Object?> body, String rel) => ((body['links'] as Map)[rel] as Map)['href'];

  test('GET /__plugins__ lists every plugin with a link to its details', () {
    extensions
      ..register(plugin: 'music-sync', version: '1.0.0', title: 'Music sync', experimental: true, handler: echo)
      ..register(plugin: 'direct-control', version: '0.1.0', title: 'Direct control', handler: echo);
    final (status, body) = call('GET', '/__plugins__', headers: const {});
    expect(status, 200);
    expect(link(body, 'self'), '/__plugins__');
    expect(body['plugins'], [
      {
        'name': 'direct-control',
        'title': 'Direct control',
        'experimental': false,
        'links': {
          'self': {'href': '/__plugins__/direct-control'},
        },
      },
      {
        'name': 'music-sync',
        'title': 'Music sync',
        'experimental': true,
        'links': {
          'self': {'href': '/__plugins__/music-sync'},
        },
      },
    ]);
  });

  test('GET /__plugins__/<plugin> gives its versions in order, each with its link, and the latest', () {
    for (final v in ['1.10.0', '1.2.0', '2.0.0']) {
      extensions.register(plugin: 'music-sync', version: v, title: 'Music sync', handler: echo);
    }
    final (status, body) = call('GET', '/__plugins__/music-sync', headers: const {});
    expect(status, 200);
    expect(body['name'], 'music-sync');
    expect([for (final v in body['versions'] as List) (v as Map)['version']], ['1.2.0', '1.10.0', '2.0.0']);
    expect(((body['versions'] as List).first as Map)['links'], {
      'self': {'href': '/__plugins__/music-sync/v1.2.0/'},
    });
    expect(link(body, 'self'), '/__plugins__/music-sync');
    expect(link(body, 'latest'), '/__plugins__/music-sync/v2.0.0/');
    expect(link(body, 'plugins'), '/__plugins__');
  });

  test("hands a versioned request to the plugin with the rest of the path, the body, the app key and its own base", () {
    extensions.register(plugin: 'music-sync', version: '1.0.0', title: 'Music sync', handler: echo);
    final (status, body) = call('PUT', '/__plugins__/music-sync/v1.0.0/settings', body: {'style': 'glow'});
    expect(status, 200);
    expect(body, {
      'path': ['settings'],
      'method': 'PUT',
      'root': '/__plugins__/music-sync/v1.0.0/',
      'settings': '/__plugins__/music-sync/v1.0.0/settings',
    });
    expect(seen.single.body, {'style': 'glow'});
    expect(seen.single.appKey, key);
    expect(call('GET', '/__plugins__/music-sync/v1.0.0/').$1, 200, reason: 'the trailing slash is the root');
  });

  test('a plugin version needs a paired app key, discovery does not', () {
    extensions.register(plugin: 'music-sync', version: '1.0.0', title: 'Music sync', handler: echo);
    expect(call('GET', '/__plugins__/music-sync/v1.0.0/', headers: const {}).$1, 401);
    final (status, body) = call('GET', '/__plugins__/music-sync/v1.0.0/', headers: const {'Hue-Application-Key': 'x'});
    expect(status, 401);
    expect((body['error'] as Map)['type'], 'unauthorized');
    expect(call('GET', '/__plugins__/music-sync', headers: const {}).$1, 200);
    expect(seen, isEmpty);
    expect(call('GET', '/__plugins__/music-sync/v1.0.0/', headers: const {'Hue-Application-Key': key}).$1, 200);
  });

  test('unknown plugins and versions are 404s that link to what there is', () {
    extensions.register(plugin: 'music-sync', version: '1.0.0', title: 'Music sync', handler: echo);
    final (missing, nobody) = call('GET', '/__plugins__/nope');
    expect(missing, 404);
    expect((nobody['error'] as Map)['type'], 'not-found');
    expect(link(nobody, 'plugins'), '/__plugins__');
    final (old, versions) = call('GET', '/__plugins__/music-sync/v3.0.0/');
    expect(old, 404);
    expect(link(versions, 'plugin'), '/__plugins__/music-sync');
    expect(call('GET', '/__plugins__/music-sync/v1/').$1, 404, reason: 'versions are full semver');
    expect(seen, isEmpty);
  });

  test('a bad body or method has its own error, and the Hue API is untouched', () {
    extensions.register(plugin: 'music-sync', version: '1.0.0', title: 'Music sync', handler: echo);
    expect(api.handle('PUT', '/__plugins__/music-sync/v1.0.0/settings', '{nope', headers: paired).$1, 400);
    expect(call('POST', '/__plugins__').$1, 405);
    expect(call('DELETE', '/__plugins__/music-sync').$1, 405);
    expect(api.handle('GET', '/api/$key/lights', '').$1, 200);
    expect(api.handle('GET', '/api/$key/lumen', '').$2, isList, reason: 'a Hue error, as before');
  });

  test('a plugin that is switched off is gone', () {
    extensions.register(plugin: 'music-sync', version: '1.0.0', title: 'Music sync', handler: echo);
    extensions.unregister('music-sync');
    expect(call('GET', '/__plugins__/music-sync/v1.0.0/').$1, 404);
    expect(call('GET', '/__plugins__').$2['plugins'], isEmpty);
  });

  test('names are kebab-case, versions are semver, and each is registered once', () {
    expect(
      () => extensions.register(plugin: 'Music_Sync', version: '1.0.0', title: 'x', handler: echo),
      throwsArgumentError,
    );
    expect(() => extensions.register(plugin: 'music', version: '1', title: 'x', handler: echo), throwsArgumentError);
    expect(() => extensions.register(plugin: 'music', version: 'v1.0.0', title: 'x', handler: echo), throwsArgumentError);
    extensions.register(plugin: 'music', version: '1.0.0', title: 'x', handler: echo);
    expect(() => extensions.register(plugin: 'music', version: '1.0.0', title: 'x', handler: echo), throwsStateError);
  });
}
