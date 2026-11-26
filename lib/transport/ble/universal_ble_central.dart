// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:typed_data';

import 'package:lumen_bonded_devices/lumen_bonded_devices.dart';
import 'package:universal_ble/universal_ble.dart' hide BleCentral;

import '../../log/logger.dart';
import 'ble_central.dart';
import 'ble_uuid.dart';
import 'hue_ble_codec.dart';

/// [BleCentral] on the device's Bluetooth stack, through universal_ble.
/// Every platform error is logged raw, before it is translated.
class UniversalBleCentral implements BleCentral {
  UniversalBleCentral({
    Logger? log,
    this.retryDelay = const Duration(milliseconds: 800),
    this.connectTimeout = const Duration(seconds: 15),
    Future<List<BondedDevice>> Function()? bondedDevices,
  }) : log = log ?? Logger.memory(),
       _bondedDevices = bondedDevices ?? BondedDevices.list;

  final Logger log;

  /// Wait before the one retry of a connect that failed with GATT error 133.
  final Duration retryDelay;
  final Duration connectTimeout;

  /// A refused permission request this fast was answered without a prompt.
  static const permanentDenialWithin = Duration(milliseconds: 400);
  final Future<List<BondedDevice>> Function() _bondedDevices;

  @override
  Future<void> ensureReady({bool request = false}) => _guard('ensureReady', () async {
    final granted = await UniversalBle.hasPermissions();
    log.debug(LogTag.ble, () => 'permissions granted: $granted');
    if (!granted) {
      if (!request) {
        log.debug(LogTag.ble, () => 'not asking for permissions without a user action');
        throw const BleOperationException(BleFailure.permissionDenied, 'not granted', 'notGranted');
      }
      final asking = Stopwatch()..start();
      try {
        log.debug(LogTag.ble, () => 'asking for permissions');
        await UniversalBle.requestPermissions();
        log.debug(LogTag.ble, () => 'permissions granted after ${asking.elapsedMilliseconds} ms');
      } catch (e) {
        _logRaw('requestPermissions', e);
        // Android answers at once, without a prompt, once the user has
        // denied for good.
        final permanent = asking.elapsed < permanentDenialWithin;
        log.debug(
          LogTag.ble,
          () => 'permissions denied after ${asking.elapsedMilliseconds} ms, ${permanent ? 'for good' : 'this time'}',
        );
        throw BleOperationException(BleFailure.permissionDenied, '$e', permanent ? 'permanentlyDenied' : 'denied');
      }
    }
    var state = await UniversalBle.getBluetoothAvailabilityState();
    log.debug(LogTag.ble, () => 'adapter state ${state.name}');
    if (state == AvailabilityState.poweredOff && request) {
      log.debug(LogTag.ble, () => 'asking to turn Bluetooth on');
      await UniversalBle.enableBluetooth().catchError((_) => false);
      state = await UniversalBle.getBluetoothAvailabilityState();
      log.debug(LogTag.ble, () => 'adapter state after asking to enable ${state.name}');
    }
    if (state == AvailabilityState.unauthorized) {
      throw const BleOperationException(BleFailure.permissionDenied, 'adapter unauthorized', 'unauthorized');
    }
    if (state != AvailabilityState.poweredOn) {
      throw BleOperationException(BleFailure.unavailable, 'adapter ${state.name}', state.name);
    }
  });

  /// Adapter state and permissions, for the log header and Diagnostics.
  @override
  Future<Map<String, String>> status() async {
    final out = <String, String>{};
    try {
      out['Bluetooth'] = (await UniversalBle.getBluetoothAvailabilityState()).name;
    } catch (e) {
      out['Bluetooth'] = 'unknown ($e)';
    }
    try {
      out['Permissions'] = await UniversalBle.hasPermissions() ? 'granted' : 'not granted';
    } catch (e) {
      out['Permissions'] = 'unknown ($e)';
    }
    return out;
  }

  @override
  Stream<BleAdvert> scan({required List<String> services}) {
    late StreamController<BleAdvert> controller;
    StreamSubscription<BleDevice>? sub;
    final wanted = {for (final s in services) BleUuid.normalize(s)};
    controller = StreamController<BleAdvert>(
      onListen: () async {
        try {
          await ensureReady();
          sub = UniversalBle.scanStream.listen((d) {
            if (d.services.isNotEmpty && !d.services.any((s) => wanted.contains(BleUuid.normalize(s)))) return;
            controller.add(
              BleAdvert(
                deviceId: d.deviceId,
                name: d.name ?? '',
                rssi: d.rssi,
                services: d.services,
                openForBonding: HueBleCodec.openForBonding(hueServiceData(d.serviceData)),
              ),
            );
          });
          log.debug(LogTag.ble, () => 'scan start, services $services');
          await UniversalBle.startScan(scanFilter: ScanFilter(withServices: wanted.toList()), skipDuplicates: true);
        } catch (e) {
          _logRaw('startScan', e);
          controller.addError(e is BleOperationException ? e : _translate(e));
        }
      },
      onCancel: () async {
        await sub?.cancel();
        log.debug(LogTag.ble, () => 'scan stop');
        await UniversalBle.stopScan().catchError((Object e) => _logRaw('stopScan', e));
      },
    );
    return controller.stream;
  }

  @override
  Future<void> connect(String deviceId) => _guard('connect', () async {
    for (var attempt = 1; ; attempt++) {
      final timing = Stopwatch()..start();
      try {
        log.debug(LogTag.ble, () => 'platform connect $deviceId, attempt $attempt');
        await UniversalBle.connect(deviceId, timeout: connectTimeout);
        log.debug(LogTag.ble, () => 'platform connected $deviceId in ${timing.elapsedMilliseconds} ms');
        break;
      } catch (e) {
        log.debug(LogTag.ble, () => 'platform connect $deviceId failed after ${timing.elapsedMilliseconds} ms');
        _logRaw('connect $deviceId', e);
        if (e is TimeoutException) {
          // Cancel the pending attempt so it does not linger in the stack.
          unawaited(UniversalBle.disconnect(deviceId).catchError((Object _) {}));
        }
        if (attempt == 1 && _retryable(e)) {
          log.debug(LogTag.ble, () => 'retrying connect $deviceId in ${retryDelay.inMilliseconds} ms');
          await Future<void>.delayed(retryDelay);
          continue;
        }
        rethrow;
      }
    }
    // Android drops the GATT table with the link, so discover on every
    // connect rather than trusting a cache a missed disconnect leaves stale.
    final services = await UniversalBle.discoverServices(deviceId);
    _gatt[deviceId.toUpperCase()] = {
      for (final s in services)
        for (final c in s.characteristics) _gattKey(s.uuid, c.uuid),
    };
    log.debug(
      LogTag.ble,
      () => [
        'services of $deviceId:',
        for (final s in services) ...[
          '  ${s.uuid}',
          for (final c in s.characteristics) '    ${c.uuid} ${c.properties.map((p) => p.name).join(',')}',
        ],
      ].join('\n'),
    );
  });

  /// The characteristics each device offered on its last connect, as
  /// [_gattKey]s, keyed by the upper-case device id.
  final Map<String, Set<String>> _gatt = {};

  static String _gattKey(String service, String characteristic) =>
      '${BleUuid.normalize(service)}/${BleUuid.normalize(characteristic)}';

  @override
  Future<bool> hasCharacteristic(String deviceId, String service, String characteristic) async {
    final known = _gatt[deviceId.toUpperCase()];
    return known == null || known.contains(_gattKey(service, characteristic));
  }

  /// GATT error 133 (GATT_ERROR) and other failed attempts often succeed
  /// on a second try.
  static bool _retryable(Object e) =>
      e is UniversalBleException &&
      (e.code == UniversalBleErrorCode.connectionFailed || RegExp(r'\b133\b').hasMatch(e.message));

  @override
  Future<void> disconnect(String deviceId) async {
    log.debug(LogTag.ble, () => 'disconnect $deviceId');
    await UniversalBle.disconnect(deviceId).catchError((Object e) => _logRaw('disconnect $deviceId', e));
  }

  @override
  Future<void> pair(String deviceId) => _guard('pair', () async {
    final timing = Stopwatch()..start();
    log.debug(LogTag.ble, () => 'platform pair $deviceId');
    await UniversalBle.pair(deviceId);
    log.debug(LogTag.ble, () => 'platform pair $deviceId ok in ${timing.elapsedMilliseconds} ms');
  }, pairing: true);

  @override
  Future<bool?> isPaired(String deviceId) => _guard('isPaired', () async {
    final paired = await UniversalBle.isPaired(deviceId);
    log.debug(LogTag.ble, () => 'platform isPaired $deviceId: $paired');
    return paired;
  });

  @override
  Future<List<BleAdvert>> knownDevices() async {
    final found = <String, BleAdvert>{};
    try {
      final bonded = await _bondedDevices();
      log.debug(LogTag.ble, () => 'bonded devices: ${[for (final d in bonded) '${d.id} "${d.name}" type ${d.type}']}');
      for (final d in bonded) {
        if (d.type != 1 && isHue(d.name, d.uuids)) {
          found[d.id.toUpperCase()] = BleAdvert(deviceId: d.id, name: d.name, services: d.uuids);
        }
      }
    } catch (e) {
      _logRaw('bondedDevices', e);
    }
    try {
      final connected = await UniversalBle.getSystemDevices();
      log.debug(LogTag.ble, () => 'system devices: ${[for (final d in connected) '${d.deviceId} "${d.name}"']}');
      for (final d in connected) {
        if (isHue(d.name ?? '', d.services)) {
          found.putIfAbsent(
            d.deviceId.toUpperCase(),
            () => BleAdvert(deviceId: d.deviceId, name: d.name ?? '', services: d.services),
          );
        }
      }
    } catch (e) {
      _logRaw('getSystemDevices', e);
    }
    return found.values.toList();
  }

  /// A Hue bulb by its default name ("Hue color lamp" and the like) or by
  /// the Hue services Android cached for it.
  static bool isHue(String name, List<String> services) {
    final uuids = services.map(BleUuid.normalize);
    if (uuids.any((s) => s.startsWith('0000fe0f') || s.startsWith('932c32bd'))) return true;
    return RegExp(r'\bhue\b', caseSensitive: false).hasMatch(name);
  }

  @override
  Future<Uint8List> read(String deviceId, String service, String characteristic) =>
      _guard('read', () => UniversalBle.read(deviceId, service, characteristic));

  @override
  Future<void> write(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value, {
    bool withoutResponse = false,
  }) => _guard(
    'write',
    () => UniversalBle.write(deviceId, service, characteristic, value, withoutResponse: withoutResponse),
  );

  @override
  Future<int> requestMtu(String deviceId, int mtu) =>
      _guard('requestMtu', () => UniversalBle.requestMtu(deviceId, mtu, timeout: const Duration(seconds: 10)));

  /// The FE0F service data, whichever form of the UUID the platform keys it by.
  static List<int>? hueServiceData(Map<String, Uint8List> serviceData) {
    for (final MapEntry(:key, :value) in serviceData.entries) {
      if (BleUuid.same(key, HueGatt.advertisedService)) return value;
    }
    return null;
  }

  @override
  Stream<Uint8List> notifications(String deviceId, String service, String characteristic) {
    late StreamController<Uint8List> controller;
    StreamSubscription<Uint8List>? sub;
    controller = StreamController<Uint8List>(
      onListen: () async {
        sub = UniversalBle.characteristicValueStream(deviceId, characteristic).listen(controller.add);
        try {
          log.debug(LogTag.ble, () => 'subscribe $deviceId $characteristic');
          await UniversalBle.subscribeNotifications(deviceId, service, characteristic);
        } catch (e) {
          _logRaw('subscribe $deviceId', e);
          controller.addError(_translate(e));
        }
      },
      onCancel: () async {
        await sub?.cancel();
        await UniversalBle.unsubscribe(deviceId, service, characteristic).catchError((_) {});
      },
    );
    return controller.stream;
  }

  @override
  Stream<bool> connectionChanges(String deviceId) => UniversalBle.connectionChangeStream(deviceId).map((c) {
    log.debug(
      LogTag.ble,
      () =>
          'connection change $deviceId: connected ${c.isConnected}, error ${c.error}, '
          'code ${c.errorCode?.name}, native ${c.nativeErrorCode}',
    );
    return c.isConnected;
  });

  Future<T> _guard<T>(String operation, Future<T> Function() body, {bool pairing = false}) async {
    try {
      return await body();
    } on BleOperationException {
      rethrow;
    } catch (e) {
      _logRaw(operation, e);
      throw _translate(e, pairing: pairing);
    }
  }

  void _logRaw(String operation, Object e) => log.debug(
    LogTag.ble,
    () => e is UniversalBleException
        ? 'universal_ble error in $operation: code ${e.code.name}, message ${e.message}, details ${e.details}'
        : 'error in $operation: ${e.runtimeType}: $e',
  );

  static BleOperationException _translate(Object e, {bool pairing = false}) {
    if (e is TimeoutException) return BleOperationException(BleFailure.timeout, '$e', 'timeout');
    final code = e is UniversalBleException ? e.code : null;
    final detail = e is UniversalBleException
        ? '${e.message}${e.details == null || '${e.details}' == e.message ? '' : ' (${e.details})'}'
        : '$e';
    var kind = switch (code) {
      UniversalBleErrorCode.notPaired ||
      UniversalBleErrorCode.notPairable ||
      UniversalBleErrorCode.pairingFailed ||
      UniversalBleErrorCode.pairingCancelled ||
      UniversalBleErrorCode.pairingTimeout ||
      UniversalBleErrorCode.pairingNotAllowed ||
      UniversalBleErrorCode.authenticationFailure ||
      UniversalBleErrorCode.insufficientAuthentication ||
      UniversalBleErrorCode.insufficientAuthorization ||
      UniversalBleErrorCode.insufficientEncryption => BleFailure.unauthenticated,
      UniversalBleErrorCode.bluetoothNotAvailable ||
      UniversalBleErrorCode.bluetoothNotEnabled => BleFailure.unavailable,
      UniversalBleErrorCode.bluetoothNotAllowed ||
      UniversalBleErrorCode.bluetoothUnauthorized => BleFailure.permissionDenied,
      UniversalBleErrorCode.deviceDisconnected || UniversalBleErrorCode.connectionTerminated => BleFailure.notConnected,
      // The bulb lacks it, or the GATT table is stale. The link is up either
      // way, so this is not a dropped connection.
      UniversalBleErrorCode.serviceNotFound || UniversalBleErrorCode.characteristicNotFound => BleFailure.notFound,
      UniversalBleErrorCode.connectionTimeout => BleFailure.timeout,
      UniversalBleErrorCode.connectionFailed ||
      UniversalBleErrorCode.connectionRejected ||
      UniversalBleErrorCode.deviceNotFound => BleFailure.unreachable,
      UniversalBleErrorCode.connectionLimitExceeded => BleFailure.connectionLimit,
      _ => BleFailure.other,
    };
    // GATT error 133 arrives as an unknown error with the status in its text.
    if (kind == BleFailure.other && _retryable(e)) kind = BleFailure.unreachable;
    // A pair call that fails for no specific reason is a refused bond.
    if (pairing && kind == BleFailure.other) kind = BleFailure.unauthenticated;
    return BleOperationException(kind, detail, code?.name ?? e.runtimeType.toString());
  }
}
