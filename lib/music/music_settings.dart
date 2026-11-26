// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/foundation.dart';

/// Where music sync hears the music.
enum AudioSource {
  /// The phone's microphone: hears the room, whatever plays the music.
  microphone,

  /// Android's Visualizer on the phone's sound output: the levels of what
  /// the phone plays, Spotify included, but no actual audio.
  phoneSound,

  /// Android 10's audio playback capture: a copy of what the phone plays,
  /// for apps that allow it, after the user agrees each time.
  capture,
}

/// How the lights move with the music.
enum MusicStyle {
  /// Every light flashes up on the beat and falls away, changing colour
  /// once a bar.
  pulse,

  /// Every beat moves each light on to the next colour of the palette.
  colours,

  /// No beats: brightness follows the loudness and colour the bass.
  glow,
}

/// What the beat styles move the lights on.
enum FollowMode {
  /// Predicted beats while the beat is steady, the hits as they come
  /// while it is not, and the last beat held when they stop.
  auto,

  /// Only predicted beats, which need a steady tempo.
  beat,

  /// Every onset as it is heard, a little late but never waiting for a
  /// steady tempo.
  hits,
}

/// The colours music sync uses, as hues in degrees.
enum MusicPalette {
  party([0, 300, 220, 160, 50]),
  warm([25, 0, 40, 340, 55]),
  cool([190, 220, 260, 170, 290]);

  const MusicPalette(this.hues);

  final List<double> hues;
}

/// What music sync is set to.
class MusicSettings {
  const MusicSettings({
    this.source = AudioSource.microphone,
    this.style = MusicStyle.pulse,
    this.palette = MusicPalette.party,
    this.roomId,
    this.strength = 0.7,
    this.timing = Duration.zero,
    this.trackingLog = false,
    this.follow = FollowMode.auto,
    this.sensitivity = 0.5,
    this.steadiness = 0.5,
    this.lightIds = const [],
  });

  final AudioSource source;
  final MusicStyle style;
  final MusicPalette palette;

  /// The room whose lights move, or null for all lights or [lightIds].
  final String? roomId;

  /// The lights picked one by one; when not empty, only these move.
  final List<String> lightIds;

  /// How strongly the lights move, from 0 (gently) to 1 (fully).
  final double strength;

  /// When the lights change against the beat they predict: later when
  /// positive, earlier when negative.
  final Duration timing;

  /// Whether music sync writes what its beat tracker decides to the log.
  final bool trackingLog;

  /// What the beat styles move the lights on.
  final FollowMode follow;

  /// How readily a sound counts as an onset, from 0 (only strong hits) to
  /// 1 (faint ones too); 0.5 is the tracker's own rule.
  final double sensitivity;

  /// How steady the beat must be to follow it, from 0 (loose) to 1
  /// (strict); 0.5 is the tracker's own rule.
  final double steadiness;

  static const minTiming = Duration(milliseconds: -300);
  static const maxTiming = Duration(milliseconds: 300);

  MusicSettings copyWith({
    AudioSource? source,
    MusicStyle? style,
    MusicPalette? palette,
    String? roomId,
    bool clearRoom = false,
    double? strength,
    Duration? timing,
    bool? trackingLog,
    FollowMode? follow,
    double? sensitivity,
    double? steadiness,
    List<String>? lightIds,
  }) => MusicSettings(
    source: source ?? this.source,
    style: style ?? this.style,
    palette: palette ?? this.palette,
    // Picked lights, a room, and all lights replace one another.
    roomId: clearRoom || (lightIds?.isNotEmpty ?? false) ? null : roomId ?? this.roomId,
    lightIds: clearRoom || roomId != null ? const [] : lightIds ?? this.lightIds,
    strength: (strength ?? this.strength).clamp(0.0, 1.0),
    timing: _clampTiming(timing ?? this.timing),
    trackingLog: trackingLog ?? this.trackingLog,
    follow: follow ?? this.follow,
    sensitivity: (sensitivity ?? this.sensitivity).clamp(0.0, 1.0),
    steadiness: (steadiness ?? this.steadiness).clamp(0.0, 1.0),
  );

  static Duration _clampTiming(Duration d) => d < minTiming
      ? minTiming
      : d > maxTiming
      ? maxTiming
      : d;

  Map<String, Object?> toJson() => {
    'version': 1,
    'source': source.name,
    'style': style.name,
    'palette': palette.name,
    'roomId': roomId,
    'strength': strength,
    'timingMs': timing.inMilliseconds,
    'trackingLog': trackingLog,
    'follow': follow.name,
    'sensitivity': sensitivity,
    'steadiness': steadiness,
    'lightIds': lightIds,
  };

  factory MusicSettings.fromJson(Map<String, Object?> json) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.where((v) => v.name == name).firstOrNull ?? fallback;
    return MusicSettings(
      source: pick(AudioSource.values, json['source'], AudioSource.microphone),
      style: pick(MusicStyle.values, json['style'], MusicStyle.pulse),
      palette: pick(MusicPalette.values, json['palette'], MusicPalette.party),
      roomId: json['roomId'] as String?,
      strength: ((json['strength'] as num?)?.toDouble() ?? 0.7).clamp(0.0, 1.0),
      timing: _clampTiming(Duration(milliseconds: (json['timingMs'] as num?)?.round() ?? 0)),
      trackingLog: json['trackingLog'] == true,
      follow: pick(FollowMode.values, json['follow'], FollowMode.auto),
      sensitivity: ((json['sensitivity'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0),
      steadiness: ((json['steadiness'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0),
      lightIds: switch (json['lightIds']) {
        final List<Object?> ids => ids.whereType<String>().toList(),
        _ => const [],
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MusicSettings &&
      other.source == source &&
      other.style == style &&
      other.palette == palette &&
      other.roomId == roomId &&
      other.strength == strength &&
      other.timing == timing &&
      other.trackingLog == trackingLog &&
      other.follow == follow &&
      other.sensitivity == sensitivity &&
      other.steadiness == steadiness &&
      listEquals(other.lightIds, lightIds);

  @override
  int get hashCode => Object.hash(
    source,
    style,
    palette,
    roomId,
    strength,
    timing,
    trackingLog,
    follow,
    sensitivity,
    steadiness,
    Object.hashAll(lightIds),
  );

  @override
  String toString() =>
      'MusicSettings(${source.name}, ${style.name}, ${palette.name}, room: $roomId, lights: $lightIds, strength: $strength, '
      'timing: ${timing.inMilliseconds} ms, tracking log: $trackingLog, follow: ${follow.name}, sensitivity: $sensitivity, steadiness: $steadiness)';
}
