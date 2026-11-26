// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'discovery_settings.dart';
import 'light.dart';

/// A paired Hue Bridge and the app key it issued.
class BridgeAccount {
  const BridgeAccount({
    required this.id,
    required this.name,
    required this.host,
    required this.appKey,
    this.removedLights = const {},
  });

  final String id;
  final String name;
  final String host;
  final String appKey;

  /// The bridge's lights the user removed from the app, by the bridge's id
  /// for them, with their names: reading the bridge again leaves them out.
  final Map<String, String> removedLights;

  BridgeAccount copyWith({Map<String, String>? removedLights}) =>
      BridgeAccount(id: id, name: name, host: host, appKey: appKey, removedLights: removedLights ?? this.removedLights);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'appKey': appKey,
    if (removedLights.isNotEmpty) 'removedLights': removedLights,
  };

  factory BridgeAccount.fromJson(Map<String, Object?> json) => BridgeAccount(
    id: json['id'] as String,
    name: json['name'] as String,
    host: json['host'] as String,
    appKey: json['appKey'] as String,
    removedLights: {
      for (final MapEntry(:key, :value) in ((json['removedLights'] as Map?) ?? const {}).entries)
        if (value is String) key as String: value,
    },
  );
}

/// A named group of lights, across transports.
class Room {
  const Room({
    required this.id,
    required this.name,
    this.icon = 'sofa',
    this.linked = false,
    this.clusterState = LightState.unknown,
    this.detached = const {},
  });

  final String id;
  final String name;
  final String icon;

  /// Linked lights act as one light: a cluster with its own settings.
  final bool linked;

  /// The cluster's own settings: what its controls last set.
  final LightState clusterState;

  /// Members the user changed on their own, which the cluster skips until
  /// they rejoin.
  final Set<String> detached;

  Room copyWith({String? name, String? icon, bool? linked, LightState? clusterState, Set<String>? detached}) => Room(
    id: id,
    name: name ?? this.name,
    icon: icon ?? this.icon,
    linked: linked ?? this.linked,
    clusterState: clusterState ?? this.clusterState,
    detached: detached ?? this.detached,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'icon': icon,
    'linked': linked,
    'clusterState': clusterState.toJson(),
    'detached': detached.toList(),
  };

  factory Room.fromJson(Map<String, Object?> json) => Room(
    id: json['id'] as String,
    name: json['name'] as String,
    icon: json['icon'] as String? ?? 'sofa',
    linked: json['linked'] as bool? ?? false,
    clusterState: json['clusterState'] is Map
        ? LightState.fromJson((json['clusterState'] as Map).cast<String, Object?>())
        : LightState.unknown,
    detached: {for (final d in (json['detached'] as List?) ?? const []) d as String},
  );
}

/// A saved look. A scene holds a state per light; a preset holds one state,
/// under [presetKey], to apply to whichever lights the user picks.
class Profile {
  const Profile({
    required this.id,
    required this.name,
    required this.states,
    this.transitionMs = 400,
    this.favorite = false,
  });

  static const presetKey = '*';

  final String id;
  final String name;
  final Map<String, LightState> states;
  final int transitionMs;
  final bool favorite;

  bool get isPreset => states.containsKey(presetKey);

  LightState? get preset => states[presetKey];

  Profile copyWith({String? name, Map<String, LightState>? states, int? transitionMs, bool? favorite}) => Profile(
    id: id,
    name: name ?? this.name,
    states: states ?? this.states,
    transitionMs: transitionMs ?? this.transitionMs,
    favorite: favorite ?? this.favorite,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'transitionMs': transitionMs,
    'favorite': favorite,
    'states': {for (final e in states.entries) e.key: e.value.toJson()},
  };

  factory Profile.fromJson(Map<String, Object?> json) => Profile(
    id: json['id'] as String,
    name: json['name'] as String,
    transitionMs: json['transitionMs'] as int? ?? 400,
    favorite: json['favorite'] as bool? ?? false,
    states: {
      for (final e in ((json['states'] as Map?) ?? const {}).entries)
        e.key as String: LightState.fromJson((e.value as Map).cast<String, Object?>()),
    },
  );
}

enum ThemeChoice { system, dark, light }

/// Everything the app persists.
class HomeSnapshot {
  const HomeSnapshot({
    this.lights = const [],
    this.bridges = const [],
    this.rooms = const [],
    this.profiles = const [],
    this.fresh = false,
    this.theme = ThemeChoice.dark,
    this.debugLogging = false,
    this.discovery = const DiscoverySettings(),
  });

  /// Which ways of finding bridges are on.
  final DiscoverySettings discovery;

  final ThemeChoice theme;

  /// Whether the log keeps debug entries, such as every Bluetooth step.
  final bool debugLogging;

  /// Nothing was ever saved: a first launch.
  static const empty = HomeSnapshot(fresh: true);

  final bool fresh;

  final List<Light> lights;
  final List<BridgeAccount> bridges;
  final List<Room> rooms;
  final List<Profile> profiles;

  static const version = 1;

  Map<String, Object?> toJson() => {
    'version': version,
    'lights': [for (final l in lights) l.toJson()],
    'bridges': [for (final b in bridges) b.toJson()],
    'rooms': [for (final r in rooms) r.toJson()],
    'profiles': [for (final p in profiles) p.toJson()],
    'theme': theme.name,
    'debugLogging': debugLogging,
    'discovery': discovery.toJson(),
  };

  factory HomeSnapshot.fromJson(Map<String, Object?> json) {
    List<T> list<T>(String key, T Function(Map<String, Object?>) f) => [
      for (final e in (json[key] as List?) ?? const []) f((e as Map).cast<String, Object?>()),
    ];
    return HomeSnapshot(
      lights: list('lights', Light.fromJson),
      bridges: list('bridges', BridgeAccount.fromJson),
      rooms: list('rooms', Room.fromJson),
      profiles: list('profiles', Profile.fromJson),
      theme: ThemeChoice.values.asNameMap()[json['theme']] ?? ThemeChoice.dark,
      debugLogging: json['debugLogging'] == true,
      discovery: DiscoverySettings.fromJson((json['discovery'] as Map?)?.cast<String, Object?>()),
    );
  }
}
