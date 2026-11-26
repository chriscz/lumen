// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/services.dart';

/// A device this phone holds a Bluetooth bond with.
class BondedDevice {
  const BondedDevice({required this.id, required this.name, this.type = 0, this.uuids = const []});

  final String id;
  final String name;

  /// Android's BluetoothDevice type: 1 classic, 2 LE, 3 dual, 0 unknown.
  final int type;

  /// Service UUIDs Android cached for the device, often empty for LE.
  final List<String> uuids;
}

/// Opens this app's page in the Android settings, where a permission the
/// user denied for good can still be granted.
abstract final class AppSettings {
  static const _channel = MethodChannel('lumen/settings');

  static Future<bool> open() async {
    try {
      return await _channel.invokeMethod<bool>('openAppSettings') ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// Android's list of bonded devices, which universal_ble does not expose.
abstract final class BondedDevices {
  static const _channel = MethodChannel('lumen/bonded_devices');

  /// The bonded devices, or an empty list where the platform has none.
  static Future<List<BondedDevice>> list() async {
    final List<Object?> raw;
    try {
      raw = await _channel.invokeListMethod<Object?>('bondedDevices') ?? const [];
    } on MissingPluginException {
      return const [];
    }
    return [
      for (final d in raw.whereType<Map<Object?, Object?>>())
        BondedDevice(
          id: '${d['id']}',
          name: '${d['name'] ?? ''}',
          type: (d['type'] as int?) ?? 0,
          uuids: [for (final u in (d['uuids'] as List<Object?>?) ?? const []) '$u'],
        ),
    ];
  }
}
