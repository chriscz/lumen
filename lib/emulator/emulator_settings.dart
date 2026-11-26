// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:math';

import '../util/hex.dart';

/// An app paired with the emulated bridge, by its app key (`username`).
class PairedApp {
  const PairedApp({
    required this.username,
    required this.devicetype,
    required this.created,
    this.clientkey,
    this.lastUsed,
  });

  final String username;

  /// What the app called itself when it paired, such as `home-assistant#lumen`.
  final String devicetype;
  final String? clientkey;
  final DateTime created;

  /// When the app last made an authorised request: its last seen time.
  final DateTime? lastUsed;

  /// How recently an app must have been seen to count as active.
  static const activeWindow = Duration(minutes: 5);

  /// Whether the app was seen within [activeWindow] of [now].
  bool activeAt(DateTime now) {
    final seen = lastUsed;
    return seen != null && now.difference(seen) <= activeWindow;
  }

  PairedApp used(DateTime at) =>
      PairedApp(username: username, devicetype: devicetype, created: created, clientkey: clientkey, lastUsed: at);

  Map<String, Object?> toJson() => {
    'username': username,
    'devicetype': devicetype,
    'clientkey': clientkey,
    'created': created.toIso8601String(),
    'lastUsed': lastUsed?.toIso8601String(),
  };

  factory PairedApp.fromJson(Map<String, Object?> json) => PairedApp(
    username: json['username'] as String,
    devicetype: json['devicetype'] as String? ?? '',
    clientkey: json['clientkey'] as String?,
    created: DateTime.tryParse(json['created'] as String? ?? '') ?? DateTime.utc(2026),
    lastUsed: DateTime.tryParse(json['lastUsed'] as String? ?? ''),
  );
}

/// Which mDNS responder announces the bridge: Android's own (NsdManager) or
/// Lumen's built-in one in Dart.
enum MdnsImplementation { system, builtIn }

/// What the emulated bridge remembers: whether it runs, its identity, the
/// apps paired with it and the numeric ids it gave the app's lights and
/// rooms. Ids are never reused, so clients keep pointing at the right light.
class EmulatorSettings {
  EmulatorSettings({
    required this.mac,
    this.name = 'Lumen',
    this.enabled = false,
    this.announce = true,
    this.port,
    this.background = true,
    this.stayAwakeWhileCharging = false,
    this.mdnsEnabled = true,
    this.ssdpEnabled = true,
    this.mdnsImplementation,
    Map<String, PairedApp>? users,
    Map<String, int>? lightIds,
    Map<String, int>? groupIds,
  }) : users = users ?? {},
       lightIds = lightIds ?? {},
       groupIds = groupIds ?? {};

  /// A new identity with a random, locally administered unicast MAC, so it
  /// cannot clash with a real device's address.
  factory EmulatorSettings.create({Random? random}) {
    final r = random ?? Random.secure();
    final bytes = List.generate(6, (_) => r.nextInt(256));
    bytes[0] = (bytes[0] | 0x02) & 0xFE;
    return EmulatorSettings(mac: hex(bytes, separator: ':'));
  }

  /// Lower case, colon separated, for example `aa:bb:cc:dd:ee:ff`.
  final String mac;
  String name;
  bool enabled;

  /// Whether the running bridge advertises itself on the Wi-Fi (mDNS and
  /// SSDP). Off, clients must be given its address.
  bool announce;

  /// The port to listen on; null tries 80, then the ports of
  /// `BridgePorts.lan` in order, and takes the first that is free.
  int? port;

  /// Whether a foreground service keeps the bridge listening while the app
  /// is in the background (Android).
  bool background;

  /// Whether to hold a CPU and Wi-Fi wake lock while the phone charges.
  bool stayAwakeWhileCharging;

  /// Whether mDNS and SSDP each announce, while [announce] is on.
  bool mdnsEnabled;
  bool ssdpEnabled;

  /// The chosen mDNS responder; null is the platform default.
  MdnsImplementation? mdnsImplementation;

  /// The mDNS responder to use: the chosen one, Android's where it exists by
  /// default, and the built-in one where there is no other.
  MdnsImplementation mdnsWanted({required bool systemAvailable}) =>
      systemAvailable ? mdnsImplementation ?? MdnsImplementation.system : MdnsImplementation.builtIn;

  final Map<String, PairedApp> users;

  /// App light id to bridge light id.
  final Map<String, int> lightIds;

  /// App room id to bridge group id.
  final Map<String, int> groupIds;

  /// The MAC without colons, as UPnP's serial number.
  String get serial => mac.replaceAll(':', '');

  /// A bridge id is the MAC with FFFE in the middle, upper case.
  String get bridgeId => '${serial.substring(0, 6)}FFFE${serial.substring(6)}'.toUpperCase();

  /// The UPnP unique device name, in the form real bridges use.
  String get udn => 'uuid:2f402f80-da50-11e1-9b23-$serial';

  Map<String, Object?> toJson() => {
    'version': 1,
    'mac': mac,
    'name': name,
    'enabled': enabled,
    'announce': announce,
    'port': port,
    'background': background,
    'stayAwakeWhileCharging': stayAwakeWhileCharging,
    'mdnsEnabled': mdnsEnabled,
    'ssdpEnabled': ssdpEnabled,
    'mdnsImplementation': mdnsImplementation?.name,
    'users': [for (final u in users.values) u.toJson()],
    'lightIds': lightIds,
    'groupIds': groupIds,
  };

  factory EmulatorSettings.fromJson(Map<String, Object?> json) => EmulatorSettings(
    mac: json['mac'] as String,
    name: json['name'] as String? ?? 'Lumen',
    enabled: json['enabled'] as bool? ?? false,
    announce: json['announce'] as bool? ?? true,
    port: json['port'] as int?,
    background: json['background'] as bool? ?? true,
    stayAwakeWhileCharging: json['stayAwakeWhileCharging'] as bool? ?? false,
    mdnsEnabled: json['mdnsEnabled'] as bool? ?? true,
    ssdpEnabled: json['ssdpEnabled'] as bool? ?? true,
    mdnsImplementation: MdnsImplementation.values.where((m) => m.name == json['mdnsImplementation']).firstOrNull,
    users: {
      for (final u in (json['users'] as List?) ?? const [])
        if (u is Map) (u['username'] as String): PairedApp.fromJson(u.cast<String, Object?>()),
    },
    lightIds: {for (final e in ((json['lightIds'] as Map?) ?? const {}).entries) e.key as String: e.value as int},
    groupIds: {for (final e in ((json['groupIds'] as Map?) ?? const {}).entries) e.key as String: e.value as int},
  );
}
