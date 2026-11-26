// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../color/color_math.dart';
import '../domain/home.dart';
import '../domain/light.dart';
import '../state/home_controller.dart';
import '../transport/bridge/hue_v1_state.dart';
import '../util/hex.dart';
import 'bridge_extensions.dart';
import 'emulator_settings.dart';

/// The Hue Bridge v1 API over the app's own lights, rooms and profiles, so
/// other apps can control them as if they were on a bridge. A pure request
/// handler: the HTTP server lives in bridge_server.dart. See
/// docs/protocol.md.
///
/// Like a real bridge it answers writes at once and lets the lights catch
/// up; [HomeController] coalesces fast repeated writes.
///
/// Beside the Hue API, `/__plugins__` serves the plugins' own APIs from
/// [extensions].
class BridgeApi {
  BridgeApi(
    this.home,
    this.settings, {
    DateTime Function()? clock,
    Random? random,
    this.onChanged,
    this.onSeen,
    BridgeExtensions? extensions,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure(),
       extensions = extensions ?? BridgeExtensions();

  final HomeController home;
  final EmulatorSettings settings;

  /// Lumen's own APIs for plugins, under `/__plugins__`.
  final BridgeExtensions extensions;

  /// Called when [settings] change and should be saved.
  final void Function()? onChanged;

  /// Called with an app's key when it makes a request after being inactive
  /// for [PairedApp.activeWindow], so the count of active apps can update.
  final void Function(String username)? onSeen;

  /// The least time between saves caused only by apps being seen.
  static const seenSaveEvery = Duration(minutes: 1);
  final DateTime Function() _clock;
  final Random _random;

  /// The address clients reach the bridge at, for the full config.
  String ipAddress = '127.0.0.1';

  static const modelId = 'BSB002';
  static const apiVersion = '1.56.0';
  static const swVersion = '1956091030';
  static const datastoreVersion = '98';
  static const linkWindow = Duration(seconds: 30);

  DateTime? _linkPressedAt;

  void pressLinkButton() => _linkPressedAt = _clock();

  /// Time left to pair, or zero.
  Duration get linkButtonRemaining {
    final pressed = _linkPressedAt;
    if (pressed == null) return Duration.zero;
    final left = linkWindow - _clock().difference(pressed);
    return left.isNegative ? Duration.zero : left;
  }

  bool get linkButtonActive => linkButtonRemaining > Duration.zero;

  DateTime? _savedAt;
  bool _unsavedSeen = false;

  void _changed() {
    _savedAt = _clock();
    _unsavedSeen = false;
    onChanged?.call();
  }

  /// Whether an app was seen since the last save, and forgets it: the
  /// emulator then saves, as when the bridge stops.
  bool takeUnsavedSeen() {
    final unsaved = _unsavedSeen;
    _unsavedSeen = false;
    return unsaved;
  }

  /// Records that [user] made a request, saving at most once a
  /// [seenSaveEvery] so a busy client does not write storage per request.
  void _seen(String user) {
    final now = _clock();
    final before = settings.users[user]!;
    if (before.lastUsed == now.toUtc()) return;
    settings.users[user] = before.used(now.toUtc());
    if (!before.activeAt(now)) onSeen?.call(user);
    final saved = _savedAt;
    if (saved == null || now.difference(saved) >= seenSaveEvery) {
      _changed();
    } else {
      _unsavedSeen = true;
    }
  }

  /// Forgets a paired app: `DELETE /config/whitelist/<key>` and Settings
  /// both come here. False when there was no such app.
  bool removeUser(String username) {
    if (settings.users.remove(username) == null) return false;
    _changed();
    return true;
  }

  /// Answers one request with an HTTP status and a JSON value. Hue API
  /// errors are HTTP 200 with an error record, as on a real bridge. [headers]
  /// carry the app key for the plugins' APIs.
  (int, Object) handle(String method, String path, String rawBody, {Map<String, String> headers = const {}}) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    final plugins = segments.isNotEmpty && segments.first == BridgeExtensions.prefix;
    if (!plugins && (segments.isEmpty || segments.first != 'api')) return (404, {'error': 'not found'});
    final rest = segments.sublist(1);
    Object? body;
    if (rawBody.trim().isNotEmpty) {
      try {
        body = jsonDecode(rawBody);
      } on FormatException {
        if (plugins) return BridgeExtensions.error(400, 'bad-request', 'The body is not valid JSON');
        return (200, [_error(2, '/${rest.join('/')}', 'body contains invalid json')]);
      }
    }
    if (plugins) {
      final key = [
        for (final MapEntry(:key, :value) in headers.entries)
          if (key.toLowerCase() == BridgeExtensions.keyHeader) value,
      ].firstOrNull;
      final paired = key != null && settings.users.containsKey(key);
      if (paired) _seen(key);
      return extensions.handle(method, rest, appKey: key, paired: paired, body: body);
    }
    try {
      return (200, _route(method, rest, body));
    } finally {
      _numberedLights = null;
    }
  }

  Object _route(String method, List<String> rest, Object? body) {
    switch ((method, rest)) {
      case ('GET', ['config']):
        return _shortConfig();
      case ('POST', []):
        return _createUser(body);
      case ('GET', [_, 'config']) when !settings.users.containsKey(rest.first):
        return _shortConfig();
      case (_, []):
        return [_error(4, '/', 'method, $method, not available for resource, /')];
      case (_, [final user, ...]) when !settings.users.containsKey(user):
        return [_error(1, '/', 'unauthorized user')];
    }
    final user = rest.first;
    _seen(user);
    final r = rest.sublist(1);
    final address = '/${r.join('/')}';
    switch ((method, r)) {
      case ('GET', []):
        return {
          'lights': _lights(),
          'groups': _groups(),
          'config': _fullConfig(),
          'scenes': _scenes(),
          'schedules': <String, Object>{},
          'sensors': <String, Object>{},
          'rules': <String, Object>{},
          'resourcelinks': <String, Object>{},
        };
      case ('GET', ['config']):
        return _fullConfig();
      case ('PUT', ['config']):
        return _putConfig(body);
      case ('DELETE', ['config', 'whitelist', final key]):
        if (!removeUser(key)) return [_error(3, address, 'resource, $address, not available')];
        return [
          {'success': '/config/whitelist/$key deleted'},
        ];
      case ('GET', ['lights']):
        return _lights();
      case ('GET', ['lights', final id]):
        final l = _lightById(id);
        return l == null ? [_notAvailable(address)] : _lightJson(l);
      case ('PUT', ['lights', final id]):
        final l = _lightById(id);
        return l == null ? [_notAvailable(address)] : _putLight(l, id, body);
      case ('PUT', ['lights', final id, 'state']):
        final l = _lightById(id);
        return l == null ? [_notAvailable(address)] : _putState([l], '/lights/$id/state', body, kind: l.kind);
      case ('GET', ['groups']):
        return _groups();
      case ('GET', ['groups', final id]):
        final g = _group(id);
        return g == null ? [_notAvailable(address)] : _groupJson(g);
      case ('PUT', ['groups', final id, 'action']):
        final g = _group(id);
        return g == null ? [_notAvailable(address)] : _putState(g.lights, '/groups/$id/action', body, group: g);
      case ('GET', ['scenes']):
        return _scenes();
      case ('GET', ['scenes', final id]):
        final p = home.profile(id);
        return p == null ? [_notAvailable(address)] : _sceneJson(p, withStates: true);
      case ('GET', ['schedules' || 'sensors' || 'rules' || 'resourcelinks']):
        return <String, Object>{};
    }
    final known = switch (r) {
      ['config' || 'lights' || 'groups' || 'scenes' || 'schedules' || 'sensors' || 'rules' || 'resourcelinks'] => true,
      ['lights', final id, ...] => _lightById(id) != null,
      ['groups', final id, ...] => _group(id) != null,
      ['scenes', final id] => home.profile(id) != null,
      _ => false,
    };
    return known
        ? [_error(4, address, 'method, $method, not available for resource, $address')]
        : [_notAvailable(address)];
  }

  // Pairing and config

  Object _createUser(Object? body) {
    if (body is! Map || body['devicetype'] is! String || (body['devicetype'] as String).isEmpty) {
      return [_error(5, '/', 'invalid/missing parameters in body')];
    }
    if (!linkButtonActive) return [_error(101, '', 'link button not pressed')];
    const alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final username = List.generate(40, (_) => alphabet[_random.nextInt(alphabet.length)]).join();
    final clientkey = body['generateclientkey'] == true
        ? hex(List.generate(16, (_) => _random.nextInt(256)), separator: '', upper: true)
        : null;
    final now = _clock().toUtc();
    settings.users[username] = PairedApp(
      username: username,
      devicetype: body['devicetype'] as String,
      clientkey: clientkey,
      created: now,
      lastUsed: now,
    );
    _changed();
    return [
      {
        'success': {'username': username, 'clientkey': ?clientkey},
      },
    ];
  }

  Map<String, Object?> _shortConfig() => {
    'name': settings.name,
    'datastoreversion': datastoreVersion,
    'swversion': swVersion,
    'apiversion': apiVersion,
    'mac': settings.mac,
    'bridgeid': settings.bridgeId,
    'factorynew': false,
    'replacesbridgeid': null,
    'modelid': modelId,
    'starterkitid': '',
  };

  static String _time(DateTime t) => t.toIso8601String().substring(0, 19);

  Map<String, Object?> _fullConfig() {
    final now = _clock();
    final octets = ipAddress.split('.');
    return {
      ..._shortConfig(),
      'zigbeechannel': 25,
      'dhcp': true,
      'ipaddress': ipAddress,
      'netmask': '255.255.255.0',
      'gateway': octets.length == 4 ? [...octets.take(3), '1'].join('.') : '0.0.0.0',
      'proxyaddress': 'none',
      'proxyport': 0,
      'UTC': _time(now.toUtc()),
      'localtime': _time(now.toLocal()),
      'timezone': 'none',
      'linkbutton': linkButtonActive,
      'portalservices': false,
      'portalconnection': 'disconnected',
      'portalstate': {'signedon': false, 'incoming': false, 'outgoing': false, 'communication': 'disconnected'},
      'swupdate2': {
        'state': 'noupdates',
        'autoinstall': {'on': false, 'updatetime': 'T14:00:00'},
      },
      'whitelist': {
        for (final u in settings.users.values)
          u.username: {
            'last use date': _time(u.lastUsed ?? u.created),
            'create date': _time(u.created),
            'name': u.devicetype,
          },
      },
    };
  }

  Object _putConfig(Object? body) {
    if (body is! Map) return [_error(5, '/config', 'invalid/missing parameters in body')];
    return [
      for (final MapEntry(:key, :value) in body.entries)
        switch (key) {
          'name' when value is String && value.trim().isNotEmpty && value.length <= 32 => _ok(
            '/config/name',
            value,
            () {
              settings.name = value.trim();
              _changed();
            },
          ),
          'linkbutton' when value == true => _ok('/config/linkbutton', value, pressLinkButton),
          'name' || 'linkbutton' => _error(7, '/config/$key', 'invalid value, $value, for parameter, $key'),
          _ => _error(6, '/config/$key', 'parameter, $key, not available'),
        },
    ];
  }

  // Lights

  /// The app's lights, except those it reaches through this emulator itself,
  /// which would otherwise come back as copies of copies.
  List<Light> get _served {
    final own = settings.bridgeId.toLowerCase();
    return home.lights.where((l) => l.bridgeId != own).toList();
  }

  /// The number [key] has in [ids], given the next free one the first time.
  int _allocate(Map<String, int> ids, String key) {
    final known = ids[key];
    if (known != null) return known;
    final next = ids.values.fold(0, max) + 1;
    ids[key] = next;
    _changed();
    return next;
  }

  String _idOf(Light l) => '${_allocate(settings.lightIds, l.id)}';

  /// The served lights with their ids, in id order, worked out once per
  /// request.
  List<(String, Light)>? _numberedLights;

  List<(String, Light)> _numbered() => _numberedLights ??= _number();

  List<(String, Light)> _number() {
    final lights = [for (final l in _served) (_allocate(settings.lightIds, l.id), l)]
      ..sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (id, l) in lights) ('$id', l)];
  }

  Light? _lightById(String id) => _numbered().where((e) => e.$1 == id).firstOrNull?.$2;

  Map<String, Object?> _lights() => {for (final (id, l) in _numbered()) id: _lightJson(l)};

  static XyColor _xyOf(LightColor? c) => switch (c) {
    final XyColor xy => xy,
    WhiteColor(:final mireds) => ColorMath.rgbToXy(ColorMath.miredsToRgb(mireds)),
    null => ColorMath.rgbToXy(ColorMath.miredsToRgb(HueRange.defaultMireds)),
  };

  static int _ctOf(LightColor? c) => switch (c) {
    WhiteColor(:final mireds) => HueRange.mireds(mireds),
    final XyColor xy => ColorMath.xyToMireds(xy),
    null => HueRange.defaultMireds,
  };

  static Map<String, Object?> _stateJson(LightKind kind, LightState s, {required bool reachable}) {
    final json = <String, Object?>{...HueV1State.encode(on: s.on ?? false, brightness: s.brightness ?? 254)};
    if (kind.hasColor) {
      final xy = _xyOf(s.color);
      final (hue, sat) = ColorMath.xyToHueSat(xy);
      json
        ..['hue'] = (hue / 360 * 65535).round() % 65536
        ..['sat'] = (sat * 254).round()
        ..['effect'] = 'none'
        ..['xy'] = HueV1State.xyJson(xy);
    }
    if (kind.hasTemperature) json['ct'] = _ctOf(s.color);
    json['alert'] = 'none';
    if (kind.hasTemperature) json['colormode'] = kind.hasColor && s.color is XyColor ? 'xy' : 'ct';
    json
      ..['mode'] = 'homeautomation'
      ..['reachable'] = reachable;
    return json;
  }

  static String _typeOf(LightKind kind) => switch (kind) {
    LightKind.color => 'Extended color light',
    LightKind.ambiance => 'Color temperature light',
    LightKind.white => 'Dimmable light',
    LightKind.onOff => 'On/Off plug-in unit',
  };

  /// A stable Zigbee-style unique id from the app's light id (FNV-1a).
  static String uniqueId(String appId) {
    var hash = 0xcbf29ce484222325;
    for (final unit in utf8.encode(appId)) {
      hash = ((hash ^ unit) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    final bytes = [for (var i = 7; i >= 0; i--) (hash >> (i * 8)) & 0xFF];
    return '${hex(bytes, separator: ':')}-0b';
  }

  Map<String, Object?> _lightJson(Light l) => {
    'state': _stateJson(l.kind, l.state, reachable: l.reachable),
    'swupdate': {'state': 'noupdates', 'lastinstall': null},
    'type': _typeOf(l.kind),
    'name': l.name,
    'modelid': switch (l.kind) {
      LightKind.color => 'LCT015',
      LightKind.ambiance => 'LTW001',
      LightKind.white => 'LWB010',
      LightKind.onOff => 'LOM001',
    },
    'manufacturername': 'Lumen',
    'productname': switch (l.kind) {
      LightKind.color => 'Lumen color light',
      LightKind.ambiance => 'Lumen white ambiance light',
      LightKind.white => 'Lumen white light',
      LightKind.onOff => 'Lumen on/off light',
    },
    'capabilities': {
      'certified': false,
      'control': {
        'mindimlevel': 1000,
        'maxlumen': 800,
        if (l.kind.hasColor) ...{
          'colorgamuttype': 'C',
          'colorgamut': [
            for (final p in [Gamut.c.red, Gamut.c.green, Gamut.c.blue]) [p.x, p.y],
          ],
        },
        if (l.kind.hasTemperature) 'ct': {'min': HueRange.minMireds, 'max': HueRange.maxMireds},
      },
      'streaming': {'renderer': false, 'proxy': false},
    },
    'config': {'archetype': 'classicbulb', 'function': 'mixed', 'direction': 'omnidirectional'},
    'uniqueid': uniqueId(l.id),
    'swversion': '1.0.0',
  };

  Object _putLight(Light l, String id, Object? body) {
    if (body is! Map) return [_error(5, '/lights/$id', 'invalid/missing parameters in body')];
    return [
      for (final MapEntry(:key, :value) in body.entries)
        switch (key) {
          'name' when value is String && value.trim().isNotEmpty && value.length <= 32 => _ok(
            '/lights/$id/name',
            value,
            () => unawaited(home.rename(l.id, value)),
          ),
          'name' => _error(7, '/lights/$id/name', 'invalid value, $value, for parameter, name'),
          _ => _error(6, '/lights/$id/$key', 'parameter, $key, not available'),
        },
    ];
  }

  // State changes, for one light or a group

  /// Applies a v1 state body to [lights]. A light checks parameters against
  /// its [kind]; a group takes any parameter and adapts it per light.
  Object _putState(List<Light> lights, String prefix, Object? body, {LightKind? kind, _Group? group}) {
    if (body is! Map) return [_error(5, prefix, 'invalid/missing parameters in body')];
    final results = <Object>[];
    final change = _Change();
    for (final MapEntry(:key, :value) in body.entries) {
      final address = '$prefix/$key';
      Object invalid() => _error(7, address, 'invalid value, $value, for parameter, $key');
      Object unavailable() => _error(6, address, 'parameter, $key, not available');
      final Object result;
      switch (key) {
        case 'on':
          result = value is bool ? _ok(address, value, () => change.on = value) : invalid();
        case 'bri':
          result = value is num
              ? _ok(address, value, () => change.bri = HueRange.brightness(value.round()))
              : invalid();
        case 'bri_inc':
          result = value is num && value.abs() <= 254
              ? _ok(address, value, () => change.briInc = value.round())
              : invalid();
        case 'xy' when kind != null && !kind.hasColor:
        case 'hue' || 'sat' when kind != null && !kind.hasColor:
        case 'ct' when kind != null && !kind.hasTemperature:
          result = unavailable();
        case 'xy':
          final xy = HueV1State.xyOf(value);
          result = xy != null && xy.x >= 0 && xy.x <= 1 && xy.y >= 0 && xy.y <= 1
              ? _ok(address, value, () => change.xy = xy)
              : invalid();
        case 'ct':
          result = value is num ? _ok(address, value, () => change.ct = HueRange.mireds(value.round())) : invalid();
        case 'hue':
          result = value is num && value >= 0 && value <= 65535
              ? _ok(address, value, () => change.hue = value.round())
              : invalid();
        case 'sat':
          result = value is num && value >= 0 && value <= 254
              ? _ok(address, value, () => change.sat = value.round())
              : invalid();
        case 'transitiontime':
          result = value is num && value >= 0
              ? _ok(address, value, () => change.transition = HueV1State.fromDeciseconds(value))
              : invalid();
        case 'alert':
          result = value is String && const ['none', 'select', 'lselect'].contains(value)
              ? _ok(address, value, () => change.alert = value != 'none')
              : invalid();
        case 'effect':
          result = value == 'none' ? _ok(address, value, () {}) : invalid();
        case 'scene' when group != null:
          final profile = home.profile(value);
          result = profile == null ? invalid() : _ok(address, value, () => change.scene = profile);
        default:
          result = unavailable();
      }
      results.add(result);
    }
    _apply(lights, change);
    return results;
  }

  void _apply(List<Light> lights, _Change change) {
    final ids = [for (final l in lights) l.id];
    if (change.scene case final profile?) {
      unawaited(home.applyProfile(profile.id, to: ids));
    }
    if (change.alert) {
      for (final id in ids) {
        unawaited(home.identify(id));
      }
    }
    // Lights that end up with the same command go out together, so a room
    // keeps its group speed on a bridge.
    unawaited(
      home.sendEach({
        for (final l in lights)
          if (change.commandFor(l) case final command when !command.isEmpty) l.id: command,
      }),
    );
  }

  // Groups

  _Group? _group(String id) {
    if (id == '0') return _Group('0', null, [for (final (_, l) in _numbered()) l]);
    final room = home.rooms.where((r) => '${_groupIdOf(r)}' == id).firstOrNull;
    if (room == null) return null;
    final inRoom = {for (final l in home.lightsIn(room.id)) l.id};
    return _Group(id, room, [
      for (final (_, l) in _numbered())
        if (inRoom.contains(l.id)) l,
    ]);
  }

  int _groupIdOf(Room room) => _allocate(settings.groupIds, room.id);

  Map<String, Object?> _groups() {
    final ids = [for (final r in home.rooms) _groupIdOf(r)]..sort();
    return {for (final id in ids) '$id': _groupJson(_group('$id')!)};
  }

  Map<String, Object?> _groupJson(_Group g) {
    final anyOn = g.lights.any((l) => l.isOn);
    final first = g.lights.firstOrNull;
    final action = first == null
        ? <String, Object?>{'on': false, 'bri': 254, 'alert': 'none'}
        : (_stateJson(first.kind, first.state, reachable: true)
            ..remove('mode')
            ..remove('reachable'));
    return {
      'name': g.room?.name ?? 'Group 0',
      'lights': [for (final l in g.lights) _idOf(l)],
      'sensors': <String>[],
      'type': g.room == null ? 'LightGroup' : 'Room',
      'state': {'all_on': g.lights.isNotEmpty && g.lights.every((l) => l.isOn), 'any_on': anyOn},
      'recycle': false,
      if (g.room != null) 'class': 'Other',
      'action': {...action, 'on': anyOn},
    };
  }

  // Scenes

  Map<String, Object?> _scenes() => {for (final p in home.profiles) p.id: _sceneJson(p)};

  /// The lights a profile covers, with the state each would get.
  List<(Light, LightState)> _sceneTargets(Profile p) => [
    for (final (_, l) in _numbered())
      if ((p.isPreset ? p.preset : p.states[l.id]) case final state?) (l, ColorMath.adapt(state, l.kind).$1),
  ];

  Map<String, Object?> _sceneJson(Profile p, {bool withStates = false}) {
    final targets = _sceneTargets(p);
    return {
      'name': p.name,
      'type': 'LightScene',
      'lights': [for (final (l, _) in targets) _idOf(l)],
      'owner': '',
      'recycle': false,
      'locked': false,
      'appdata': <String, Object>{},
      'picture': '',
      'lastupdated': null,
      'version': 2,
      if (withStates)
        'lightstates': {
          for (final (l, s) in targets)
            _idOf(l): HueV1State.encode(
              on: s.on ?? true,
              brightness: s.brightness ?? 254,
              color: s.color,
              transition: Duration(milliseconds: p.transitionMs),
              clampCt: false,
            ),
        },
    };
  }

  // Records

  static Map<String, Object> _ok(String address, Object? value, void Function() apply) {
    apply();
    return {
      'success': {address: value},
    };
  }

  static Map<String, Object> _notAvailable(String address) => _error(3, address, 'resource, $address, not available');

  static Map<String, Object> _error(int type, String address, String description) => {
    'error': {'type': type, 'address': address, 'description': description},
  };
}

class _Group {
  _Group(this.id, this.room, this.lights);

  final String id;

  /// Null for group 0, every light.
  final Room? room;
  final List<Light> lights;
}

/// The fields of one state body, before they are turned into a command per
/// light.
class _Change {
  bool? on;
  int? bri;
  int? briInc;
  XyColor? xy;
  int? ct;
  int? hue;
  int? sat;
  Duration? transition;
  bool alert = false;
  Profile? scene;

  /// The command for [l]: brightness steps from its own level, hue or
  /// saturation alone keep the other from its colour, and a colour it cannot
  /// show becomes the nearest it can. xy wins over ct, ct over hue and sat.
  LightCommand commandFor(Light l) {
    final brightness = bri ?? (briInc == null ? null : HueRange.brightness((l.state.brightness ?? 254) + briInc!));
    LightColor? color = xy ?? (ct == null ? null : WhiteColor(ct!));
    if (color == null && (hue != null || sat != null)) {
      final (h, s) = ColorMath.xyToHueSat(BridgeApi._xyOf(l.state.color));
      color = ColorMath.hueSatToXy(hue == null ? h : hue! / 65535 * 360, sat == null ? s : sat! / 254);
    }
    if (color != null) color = ColorMath.adapt(LightState(color: color), l.kind).$1.color;
    return LightCommand(on: on, brightness: brightness, color: color, transition: transition);
  }
}
