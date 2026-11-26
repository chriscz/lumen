// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../domain/errors.dart';
import '../../domain/light.dart';
import '../../log/logger.dart';
import 'hue_v1_state.dart';

class BridgeConfig {
  const BridgeConfig({required this.id, required this.name});

  final String id;
  final String name;
}

class BridgeLight {
  const BridgeLight({
    required this.id,
    required this.name,
    required this.kind,
    required this.state,
    required this.reachable,
  });

  final String id;
  final String name;
  final LightKind kind;
  final LightState state;
  final bool reachable;
}

class BridgeGroup {
  const BridgeGroup({required this.id, required this.name, required this.lightIds, required this.type});

  final String id;
  final String name;
  final List<String> lightIds;
  final String type;

  bool get isRoom => type == 'Room' || type == 'Zone';
}

/// The Hue Bridge local API, version 1. See
/// docs/protocol.md.
class HueBridgeClient {
  HueBridgeClient(this._http, this.base, {this.timeout = const Duration(seconds: 5), Logger? log})
    : log = log ?? Logger.memory();

  /// A client for a real bridge at [host]. Bridges serve HTTPS with a
  /// certificate from the Signify CA, which Android does not trust, so the
  /// certificate is accepted for that host only.
  ///
  /// An address with a port, such as `192.168.1.20:1818`, is an emulated
  /// bridge (another phone running Lumen), which speaks plain HTTP.
  factory HueBridgeClient.forHost(String host, {Logger? log}) {
    final base = baseFor(host);
    return HueBridgeClient(IOClient(httpClientFor(base.host)), base, log: log);
  }

  /// An HTTP client that accepts any certificate from [trustedHost], and
  /// only the usual trusted ones from anywhere else.
  static HttpClient httpClientFor(String trustedHost) => HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..badCertificateCallback = (cert, certHost, port) => certHost == trustedHost;

  /// `https://host` for a bare address, `http://host:port` when a port is given.
  static Uri baseFor(String host) {
    final h = host.trim();
    final withPort = RegExp(r'^([^:\[\]]+|\[[0-9a-fA-F:.]+\]):(\d{1,5})$').hasMatch(h);
    return Uri.parse(withPort ? 'http://$h' : 'https://$h');
  }

  final http.Client _http;
  final Uri base;
  final Duration timeout;
  final Logger log;

  static final _keyInPath = RegExp(r'^/api/([^/]+)');

  /// [path] with the app key cut to its first four characters.
  static String redactPath(String path) => path.replaceFirstMapped(
    _keyInPath,
    (m) => m.group(1) == 'config' ? m.group(0)! : '/api/${Logger.redact(m.group(1)!)}',
  );

  static const deviceType = 'lumen#android';

  Future<BridgeConfig> config() async {
    final json = await _send('GET', '/api/config') as Map<String, Object?>;
    return BridgeConfig(id: '${json['bridgeid'] ?? ''}'.toLowerCase(), name: '${json['name'] ?? 'Hue Bridge'}');
  }

  /// Asks for an app key. Succeeds only within 30 s of a link button press.
  Future<String> pair() async {
    final json = await _send('POST', '/api', {'devicetype': deviceType});
    if (json is! List || json.isEmpty || json.first is! Map) throw _unexpected;
    final first = json.first as Map;
    if (first['success'] case {'username': final String key}) return key;
    throw _error(first['error']);
  }

  /// Polls [pair] until the link button is pressed, or [timeout] passes.
  Future<String> waitForLinkButton({
    Duration interval = const Duration(seconds: 1),
    Duration timeout = const Duration(seconds: 30),
    bool Function()? cancelled,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        return await pair();
      } on LinkButtonNotPressed {
        if (DateTime.now().isAfter(deadline) || (cancelled?.call() ?? false)) rethrow;
      }
      await Future<void>.delayed(interval);
    }
  }

  Future<List<BridgeLight>> lights(String key) async {
    final json = await _send('GET', '/api/$key/lights');
    if (json is List) throw _error(json.firstOrNull is Map ? (json.first as Map)['error'] : null);
    if (json is! Map<String, Object?>) throw _unexpected;
    return [
      for (final MapEntry(:key, :value) in json.entries)
        if (value is Map) _light(key, value.cast<String, Object?>()),
    ];
  }

  Future<List<BridgeGroup>> groups(String key) async {
    final json = await _send('GET', '/api/$key/groups');
    if (json is List) throw _error(json.firstOrNull is Map ? (json.first as Map)['error'] : null);
    if (json is! Map<String, Object?>) throw _unexpected;
    return [
      for (final MapEntry(:key, :value) in json.entries)
        if (value case final Map g)
          BridgeGroup(
            id: key,
            name: '${g['name'] ?? 'Group $key'}',
            type: '${g['type'] ?? ''}',
            lightIds: [for (final l in (g['lights'] as List?) ?? const []) '$l'],
          ),
    ];
  }

  Future<void> setState(String key, String lightId, LightCommand command) async {
    final json = await _send('PUT', '/api/$key/lights/$lightId/state', HueV1State.fromCommand(command));
    _checkResults(json);
  }

  /// Sets every light of group [groupId] in one call. Group 0 is every
  /// light on the bridge.
  Future<void> groupAction(String key, String groupId, LightCommand command) async {
    final json = await _send('PUT', '/api/$key/groups/$groupId/action', HueV1State.fromCommand(command));
    _checkResults(json);
  }

  /// Makes the light blink once, to find it.
  Future<void> alert(String key, String lightId) async {
    final json = await _send('PUT', '/api/$key/lights/$lightId/state', {'alert': 'select'});
    _checkResults(json);
  }

  static BridgeLight _light(String id, Map<String, Object?> json) {
    final state = (json['state'] as Map?)?.cast<String, Object?>() ?? const {};
    return BridgeLight(
      id: id,
      name: '${json['name'] ?? 'Light $id'}',
      kind: kindForType('${json['type'] ?? ''}'),
      reachable: state['reachable'] as bool? ?? true,
      state: HueV1State.stateOf(state),
    );
  }

  static LightKind kindForType(String type) => switch (type.toLowerCase()) {
    final t when t.contains('color light') => LightKind.color,
    final t when t.contains('temperature') => LightKind.ambiance,
    final t when t.contains('on/off') => LightKind.onOff,
    _ => LightKind.white,
  };

  static const _unexpected = BridgeUnreachable('The bridge sent an unexpected answer.');

  /// Write calls answer with a list of success or error records.
  static void _checkResults(Object? json) {
    if (json is! List) throw _unexpected;
    for (final entry in json) {
      if (entry is Map && entry['error'] != null) throw _error(entry['error']);
    }
  }

  static LightError _error(Object? error) => switch (error) {
    {'type': 101} => const LinkButtonNotPressed(),
    {'type': 1} => const BridgeUnauthorized(),
    {'description': final String d} => BridgeUnreachable('The bridge said: $d'),
    _ => const BridgeUnreachable('The bridge sent an unexpected answer.'),
  };

  Future<Object?> _send(String method, String path, [Object? body]) async {
    final request = http.Request(method, base.replace(path: path));
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final shown = redactPath(path);
    final timing = Stopwatch()..start();
    try {
      final response = await http.Response.fromStream(await _http.send(request).timeout(timeout));
      final summary =
          '$method $shown ${response.statusCode}, ${response.bodyBytes.length} bytes, ${timing.elapsedMilliseconds} ms';
      if (response.statusCode >= 400) {
        log.warning(LogTag.bridge, summary);
        throw BridgeUnreachable('The bridge answered with HTTP ${response.statusCode}.');
      }
      log.debug(LogTag.bridge, () => summary);
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on LightError {
      rethrow;
    } on Exception catch (e) {
      log.warning(LogTag.bridge, '$method $shown failed after ${timing.elapsedMilliseconds} ms: $e');
      throw const BridgeOffline();
    }
  }
}
