// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';

import '../emulator/bridge_extensions.dart';
import 'music_settings.dart';
import 'music_sync.dart';

/// Music sync's API on the emulated bridge, at
/// `/__plugins__/music-sync/v1.0.0/`. Every answer links to the actions
/// that make sense next, so clients follow links rather than build paths:
///
/// - `GET /` the status: phase, tempo, beats, loudness, problem and hint,
///   the settings, each source's status, the rooms to choose from and how
///   many lights move. Links: `settings`, and `start` or `stop`.
/// - `PUT /settings` some of `source`, `style`, `palette`, `roomId` (null
///   for all lights), `strength` and `timingMs`; answers the settings.
/// - `POST /start` answers 202 at once; read the status to follow it. A
///   phone in the background may not be allowed to start the microphone.
/// - `POST /stop` stops and puts the lights back.
class MusicSyncApi {
  MusicSyncApi(this.music);

  /// The version this class serves.
  static const version = '1.0.0';

  final MusicSync music;

  static const _settingKeys = {'source', 'style', 'palette', 'roomId', 'strength', 'timingMs'};

  (int, Object) handle(ExtensionRequest r) => switch ((r.method, r.path)) {
    ('GET', []) => (200, status(r)),
    ('PUT', ['settings']) => _settings(r),
    ('POST', ['start']) => _start(r),
    ('POST', ['stop']) => _stop(r),
    (_, [] || ['settings'] || ['start'] || ['stop']) => BridgeExtensions.error(
      405,
      'method-not-allowed',
      '${r.method} is not allowed on /${r.path.join('/')}',
    ),
    _ => BridgeExtensions.error(404, 'not-found', 'Music sync has no /${r.path.join('/')}'),
  };

  Map<String, Object?> status(ExtensionRequest r) => {
    // v1.0.0 knows only its own phases.
    'phase': switch (music.phase) {
      MusicSyncPhase.holding => MusicSyncPhase.following.name,
      MusicSyncPhase.breathing || MusicSyncPhase.hits => MusicSyncPhase.listening.name,
      final p => p.name,
    },
    'bpm': music.bpm,
    'beats': music.beats,
    'level': music.level,
    'problem': music.problem,
    'hint': music.hint,
    'settings': _settingsJson(music.settings),
    'sources': {
      for (final MapEntry(key: source, value: s) in music.sources.entries)
        source.name: {'state': s.state.name, 'reason': s.reason},
    },
    'rooms': [
      for (final room in music.home.rooms) {'id': room.id, 'name': room.name},
    ],
    'lights': music.targets.length,
    'links': {
      'self': {'href': r.href()},
      'settings': {'href': r.href('settings'), 'method': 'PUT'},
      if (music.running || music.phase == MusicSyncPhase.starting)
        'stop': {'href': r.href('stop'), 'method': 'POST'}
      else
        'start': {'href': r.href('start'), 'method': 'POST'},
      'plugin': {'href': r.base.substring(0, r.base.lastIndexOf('/'))},
    },
  };

  /// The settings v1.0.0 has: later ones stay out of it.
  static Map<String, Object?> _settingsJson(MusicSettings s) => {
    for (final MapEntry(:key, :value) in s.toJson().entries)
      if (_settingKeys.contains(key)) key: value,
  };

  (int, Object) _settings(ExtensionRequest r) {
    final body = r.body;
    if (body is! Map) return BridgeExtensions.error(400, 'bad-request', 'Send a JSON object of settings');
    final unknown = body.keys.where((k) => !_settingKeys.contains(k)).toList();
    if (unknown.isNotEmpty) return BridgeExtensions.error(400, 'bad-request', 'Unknown settings: ${unknown.join(', ')}');
    T? pick<T extends Enum>(List<T> values, String key) =>
        body.containsKey(key) ? values.where((v) => v.name == body[key]).firstOrNull : null;
    String? invalid;
    final source = pick(AudioSource.values, 'source');
    final style = pick(MusicStyle.values, 'style');
    final palette = pick(MusicPalette.values, 'palette');
    for (final (key, value) in [('source', source), ('style', style), ('palette', palette)]) {
      if (body.containsKey(key) && value == null) invalid = '$key cannot be ${body[key]}';
    }
    final room = body['roomId'];
    if (room != null && (room is! String || music.home.room(room) == null)) invalid = 'There is no room $room';
    final strength = body['strength'];
    if (strength != null && strength is! num) invalid = 'strength must be a number from 0 to 1';
    final timing = body['timingMs'];
    if (timing != null && timing is! num) invalid = 'timingMs must be a number of milliseconds';
    if (invalid != null) return BridgeExtensions.error(400, 'bad-request', invalid);

    final next = music.settings.copyWith(
      source: source,
      style: style,
      palette: palette,
      roomId: room as String?,
      clearRoom: body.containsKey('roomId') && room == null,
      strength: (strength as num?)?.toDouble(),
      timing: timing == null ? null : Duration(milliseconds: (timing as num).round()),
    );
    unawaited(music.update(next));
    return (200, {
      'settings': _settingsJson(next),
      'links': {
        'self': {'href': r.href('settings'), 'method': 'PUT'},
        'status': {'href': r.href()},
      },
    });
  }

  (int, Object) _start(ExtensionRequest r) {
    if (music.home.lights.isEmpty) {
      return BridgeExtensions.error(409, 'conflict', 'There are no lights to move', links: {'status': r.href()});
    }
    unawaited(music.start());
    return (202, status(r));
  }

  (int, Object) _stop(ExtensionRequest r) {
    unawaited(music.stop());
    return (200, status(r));
  }
}
