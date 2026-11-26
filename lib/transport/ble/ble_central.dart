// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:typed_data';

/// One advertisement seen during a scan.
class BleAdvert {
  const BleAdvert({
    required this.deviceId,
    required this.name,
    this.rssi,
    this.services = const [],
    this.openForBonding,
  });

  final String deviceId;
  final String name;
  final int? rssi;
  final List<String> services;

  /// From the FE0F service data: the bulb accepts a new bond now. Null when
  /// the advertisement does not say.
  final bool? openForBonding;
}

/// Failure of a GATT operation, with enough detail to tell an unbonded bulb
/// from one that is out of range.
class BleOperationException implements Exception {
  const BleOperationException(this.kind, [this.detail = '', this.code]);

  final BleFailure kind;
  final String detail;

  /// The platform's own error code, such as `connectionFailed`, kept for
  /// diagnostics.
  final String? code;

  @override
  String toString() =>
      'BleOperationException($kind${code == null ? '' : ' $code'}${detail.isEmpty ? '' : ': $detail'})';
}

enum BleFailure {
  notConnected,

  /// The device does not offer the service or characteristic, or the
  /// phone's cached GATT table is stale.
  notFound,
  unreachable,
  unauthenticated,
  unavailable,
  permissionDenied,

  /// The phone holds as many links as its controller allows.
  connectionLimit,

  /// The device did not answer in time. A bulb that advertises but does not
  /// accept a connection is usually held by another phone or the Hue app.
  timeout,
  other,
}

/// The slice of a Bluetooth LE central the app needs. A real implementation
/// wraps the platform plugin; the simulated one serves the tests and the demo.
abstract interface class BleCentral {
  /// Checks the adapter and the runtime permissions. Only when [request] is
  /// set does it prompt for a missing permission or ask to turn Bluetooth
  /// on; that must follow a user action, or the prompt loops. A permission
  /// the user denied for good fails with code `permanentlyDenied`.
  Future<void> ensureReady({bool request = false});

  /// Adapter state and permissions as labels, for the log and Diagnostics.
  /// Never prompts.
  Future<Map<String, String>> status();

  /// Advertisements of devices that advertise one of [services]. Scanning
  /// stops when the subscription is cancelled.
  Stream<BleAdvert> scan({required List<String> services});

  Future<void> connect(String deviceId);

  Future<void> disconnect(String deviceId);

  /// Bonds with the device. Completes when bonded.
  Future<void> pair(String deviceId);

  /// Whether this phone holds a bond with the device, or null when the
  /// platform cannot tell.
  Future<bool?> isPaired(String deviceId);

  /// Hue bulbs this phone already knows: bonded, or connected by another
  /// app. A bonded bulb often does not advertise, so a scan misses it.
  Future<List<BleAdvert>> knownDevices();

  /// Whether [deviceId] offers [characteristic] in [service], from the
  /// services discovered on the last connect. True when that is not known,
  /// so the read or write itself decides.
  Future<bool> hasCharacteristic(String deviceId, String service, String characteristic);

  Future<Uint8List> read(String deviceId, String service, String characteristic);

  Future<void> write(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value, {
    bool withoutResponse = false,
  });

  /// Asks for a larger MTU; returns the MTU granted.
  Future<int> requestMtu(String deviceId, int mtu);

  /// Notifications from [characteristic]. Subscribes on listen.
  Stream<Uint8List> notifications(String deviceId, String service, String characteristic);

  /// Emits false when the device drops the connection.
  Stream<bool> connectionChanges(String deviceId);
}
