// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/log/logger.dart';
import 'package:lumen/transport/ble/ble_central.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';
import 'package:lumen/transport/ble/universal_ble_central.dart';
import 'package:lumen_bonded_devices/lumen_bonded_devices.dart';
import 'package:universal_ble/universal_ble.dart' hide BleCentral;

/// universal_ble's platform layer, scripted per test.
class FakePlatform extends UniversalBlePlatform {
  /// Results of successive connect calls: null connects, a number fails
  /// with that GATT status, 'hang' never answers.
  final List<Object?> connectResults = [];
  int connects = 0;
  bool pairResult = true;
  bool paired = false;
  List<BleDevice> systemDevices = [];
  List<BleService> services = [
    BleService(HueGatt.lightService, [
      BleCharacteristic(HueGatt.power, [CharacteristicProperty.read, CharacteristicProperty.notify], []),
    ]),
  ];

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    connects++;
    final result = connectResults.isEmpty ? null : connectResults.removeAt(0);
    if (result == 'hang') return;
    Future<void>.delayed(Duration.zero, () {
      if (result is int) {
        updateConnection(deviceId, false, 'Unknown Error $result', UniversalBleErrorCode.connectionFailed, result);
      } else {
        updateConnection(deviceId, true);
      }
    });
  }

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors, {
    DiscoverServicesPlatformConfig? platformConfig,
    Duration? timeout,
  }) async => services;

  bool granted = true;
  int requests = 0;

  /// The user grants the permission when asked.
  bool grantOnRequest = false;

  /// How long the user takes to answer the permission prompt.
  Duration requestDelay = Duration.zero;
  Object? permissionsError;

  @override
  Future<bool> hasPermissions({bool withAndroidFineLocation = false}) async {
    if (permissionsError case final e?) throw e;
    return granted;
  }

  @override
  Future<void> requestPermissions({bool withAndroidFineLocation = false}) async {
    requests++;
    await Future<void>.delayed(requestDelay);
    if (grantOnRequest) granted = true;
    if (!granted) throw UniversalBleException(code: UniversalBleErrorCode.bluetoothNotAllowed, message: 'denied');
  }

  AvailabilityState availability = AvailabilityState.poweredOn;
  Object? availabilityError;

  /// The adapter state after the user answers the enable prompt; null
  /// makes the prompt fail.
  AvailabilityState? afterEnable;
  int enables = 0;

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async {
    if (availabilityError case final e?) throw e;
    return availability;
  }

  @override
  Future<bool> enableBluetooth() async {
    enables++;
    final next = afterEnable;
    if (next == null) throw UniversalBleException(code: UniversalBleErrorCode.bluetoothNotEnabled, message: 'refused');
    availability = next;
    return true;
  }

  @override
  Future<bool> pair(String deviceId) async => pairResult;

  @override
  Future<bool> isPaired(String deviceId) async => paired;

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async => BleConnectionState.disconnected;

  Object? systemDevicesError;

  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async {
    if (systemDevicesError case final e?) throw e;
    return systemDevices;
  }

  final List<String> disconnects = [];

  @override
  Future<void> disconnect(String deviceId) async => disconnects.add(deviceId);

  /// Errors that reads of a characteristic fail with, of any type.
  final Map<String, Object> readErrors = {};

  @override
  Future<Uint8List> readValue(String deviceId, String service, String characteristic, {Duration? timeout}) async {
    if (readErrors[characteristic] case final e?) throw e;
    return Uint8List.fromList([1]);
  }

  /// Every write, as (characteristic, comma-separated bytes, property).
  final List<(String, String, BleOutputProperty)> writes = [];
  Object? writeError;

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {
    if (writeError case final e?) throw e;
    writes.add((characteristic, value.join(','), bleOutputProperty));
  }

  /// The MTU the link settles on, whatever is asked.
  int negotiatedMtu = 247;
  final List<int> mtuRequests = [];

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    mtuRequests.add(expectedMtu);
    return negotiatedMtu;
  }

  /// Every subscription change, as (characteristic, property).
  final List<(String, BleInputProperty)> notifiable = [];
  Object? subscribeError;
  Object? unsubscribeError;

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {
    notifiable.add((characteristic, bleInputProperty));
    final error = bleInputProperty == BleInputProperty.disabled ? unsubscribeError : subscribeError;
    if (error != null) throw error;
  }

  int scansStarted = 0;
  Object? scanError;

  @override
  Future<void> startScan({ScanFilter? scanFilter, PlatformConfig? platformConfig}) async {
    if (scanError case final e?) throw e;
    scansStarted++;
  }

  @override
  Future<void> stopScan() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late FakePlatform platform;
  late Logger log;
  late List<BondedDevice> bonded;
  late UniversalBleCentral central;

  setUp(() {
    platform = FakePlatform();
    UniversalBle.setInstance(platform);
    log = Logger.memory()..debugEnabled = true;
    bonded = [];
    central = UniversalBleCentral(
      log: log,
      retryDelay: const Duration(milliseconds: 5),
      connectTimeout: const Duration(milliseconds: 200),
      bondedDevices: () async => bonded,
    );
  });

  String debugText() => log.entries.map((e) => e.message).join('\n');

  test('retries a connect once after GATT error 133', () async {
    platform.connectResults.add(133);
    await central.connect('AA:01');
    expect(platform.connects, 2);
    expect(debugText(), contains('133'));
    expect(debugText(), contains('retrying'));
  });

  test('gives up after the retry and keeps the raw error', () async {
    platform.connectResults.addAll([133, 133]);
    final error = await central.connect('AA:01').then<Object?>((_) => null, onError: (Object e) => e);
    expect(platform.connects, 2);
    expect(error, isA<BleOperationException>());
    expect((error as BleOperationException).kind, BleFailure.unreachable);
    expect(error.detail, contains('133'));
    expect(debugText(), contains('universal_ble error'));
  });

  test('a connect that never answers is a timeout', () async {
    platform.connectResults.addAll(['hang', 'hang']);
    final error = await central.connect('AA:01').then<Object?>((_) => null, onError: (Object e) => e);
    expect((error as BleOperationException).kind, BleFailure.timeout);
    expect(platform.connects, 1, reason: 'a timeout is not retried: the bulb is busy');
  });

  test('logs the services and characteristics found on connect', () async {
    await central.connect('AA:01');
    expect(debugText(), contains('932c32bd-0000'));
    expect(debugText(), contains('932c32bd-0002'));
  });

  test('a refused bond is unauthenticated', () async {
    platform.pairResult = false;
    final error = await central.pair('AA:01').then<Object?>((_) => null, onError: (Object e) => e);
    expect((error as BleOperationException).kind, BleFailure.unauthenticated);
  });

  test('ensureReady does not prompt for a missing permission unless asked to', () async {
    platform.granted = false;
    final error = await central.ensureReady().then<Object?>((_) => null, onError: (Object e) => e);
    expect((error as BleOperationException).kind, BleFailure.permissionDenied);
    expect(platform.requests, 0);
  });

  test('a request refused without a prompt counts as denied for good', () async {
    platform.granted = false;
    final error = await central.ensureReady(request: true).then<Object?>((_) => null, onError: (Object e) => e);
    expect(platform.requests, 1);
    expect((error as BleOperationException).code, 'permanentlyDenied');
  });

  test('ensureReady passes with permissions and the adapter on', () async {
    await central.ensureReady();
    expect(platform.requests, 0);
  });

  test('isPaired reports the bond state', () async {
    platform.paired = true;
    expect(await central.isPaired('AA:01'), isTrue);
  });

  test('known devices are bonded or connected Hue bulbs, without duplicates', () async {
    bonded = [
      const BondedDevice(id: 'AA:01', name: 'Hue color lamp', type: 2),
      const BondedDevice(id: 'AA:02', name: 'Headphones', type: 1),
      const BondedDevice(id: 'AA:03', name: 'Lamp', type: 2, uuids: [HueGatt.advertisedService]),
    ];
    platform.systemDevices = [
      BleDevice(deviceId: 'AA:01', name: 'Hue color lamp'),
      BleDevice(deviceId: 'AA:04', name: 'Hue white lamp'),
      BleDevice(deviceId: 'AA:05', name: 'Watch'),
    ];
    final known = await central.knownDevices();
    expect(known.map((d) => d.deviceId), ['AA:01', 'AA:03', 'AA:04']);
  });

  test('finds the FE0F service data under either form of the UUID', () {
    final data = Uint8List.fromList([0, 0, 4]);
    expect(UniversalBleCentral.hueServiceData({'0000fe0f-0000-1000-8000-00805f9b34fb': data}), data);
    expect(UniversalBleCentral.hueServiceData({'FE0F': data}), data);
    expect(UniversalBleCentral.hueServiceData({'180a': data}), isNull);
  });

  test('a missing characteristic or service is notFound, not a dropped link', () async {
    await central.connect('AA:01');
    platform.readErrors[HueGatt.minDim] = UniversalBleException(
      code: UniversalBleErrorCode.characteristicNotFound,
      message: 'Characteristic not found',
    );
    platform.readErrors[HueGatt.securityKey] = UniversalBleException(
      code: UniversalBleErrorCode.serviceNotFound,
      message: 'Service not found',
    );
    for (final (service, characteristic) in [
      (HueGatt.lightService, HueGatt.minDim),
      (HueGatt.configService, HueGatt.securityKey),
    ]) {
      final error = await central
          .read('AA:01', service, characteristic)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((error as BleOperationException).kind, BleFailure.notFound, reason: characteristic);
    }
  });

  test('remembers the characteristics discovered on connect', () async {
    platform.services = [
      BleService('932C32BD-0000-47A2-835A-A8D455B859DD', [
        BleCharacteristic('932C32BD-0007-47A2-835A-A8D455B859DD', [CharacteristicProperty.write], []),
        BleCharacteristic(HueGatt.minDim, [CharacteristicProperty.write], []),
      ]),
    ];
    await central.connect('AA:01');
    expect(await central.hasCharacteristic('AA:01', HueGatt.lightService, HueGatt.control), isTrue);
    expect(await central.hasCharacteristic('aa:01', HueGatt.lightService, HueGatt.minDim), isTrue);
    expect(await central.hasCharacteristic('AA:01', HueGatt.lightService, HueGatt.startup), isFalse);
    expect(await central.hasCharacteristic('AA:01', HueGatt.configService, HueGatt.minDim), isFalse);

    platform.services = [
      BleService(HueGatt.lightService, [
        BleCharacteristic(HueGatt.control, [CharacteristicProperty.write], []),
      ]),
    ];
    await central.connect('AA:01');
    expect(
      await central.hasCharacteristic('AA:01', HueGatt.lightService, HueGatt.minDim),
      isFalse,
      reason: 'each connect discovers the table again',
    );
  });

  group('scan filter', () {
    Future<List<BleAdvert>> advertise(List<BleDevice> devices, {String filter = HueGatt.advertisedService}) async {
      final seen = <BleAdvert>[];
      final before = platform.scansStarted;
      final sub = central.scan(services: [filter]).listen(seen.add);
      while (platform.scansStarted == before) {
        await Future<void>.delayed(Duration.zero);
      }
      devices.forEach(platform.updateScanResult);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      return seen;
    }

    test('matches the Hue service in any case and in its short form', () async {
      final seen = await advertise([
        BleDevice(deviceId: 'AA:01', name: 'Short', services: ['FE0F']),
        BleDevice(deviceId: 'AA:02', name: 'Upper', services: ['0000FE0F-0000-1000-8000-00805F9B34FB']),
        BleDevice(deviceId: 'AA:03', name: 'Lower', services: ['fe0f']),
        BleDevice(deviceId: 'AA:04', name: 'Other', services: ['180D']),
      ]);
      expect(seen.map((a) => a.name), ['Short', 'Upper', 'Lower']);
    });

    test('a filter in short or upper-case form matches too', () async {
      for (final filter in ['FE0F', 'fe0f', '0000FE0F-0000-1000-8000-00805F9B34FB']) {
        final seen = await advertise([
          BleDevice(deviceId: 'AA:01', name: 'Hue', services: [HueGatt.advertisedService]),
          BleDevice(deviceId: 'AA:02', name: 'Other', services: ['180D']),
        ], filter: filter);
        expect(seen.map((a) => a.name), ['Hue'], reason: filter);
      }
    });

    test('keeps an advert that lists no services, as some platforms send', () async {
      final seen = await advertise([BleDevice(deviceId: 'AA:01', name: 'Bare')]);
      expect(seen.map((a) => a.name), ['Bare']);
    });

    test('an advert carries its signal, a missing name as empty and the bonding flag', () async {
      final seen = await advertise([
        BleDevice(
          deviceId: 'AA:01',
          name: null,
          rssi: -61,
          services: [HueGatt.advertisedService],
          serviceData: {
            'fe0f': Uint8List.fromList([0, 0, 0x04]),
          },
        ),
        BleDevice(
          deviceId: 'AA:02',
          name: 'Closed',
          services: [HueGatt.advertisedService],
          serviceData: {
            'fe0f': Uint8List.fromList([0, 0, 0]),
          },
        ),
        BleDevice(deviceId: 'AA:03', name: 'No data', services: [HueGatt.advertisedService]),
      ]);
      expect(seen.map((a) => a.name), ['', 'Closed', 'No data']);
      expect(seen.map((a) => a.rssi), [-61, null, null]);
      expect(seen.map((a) => a.openForBonding), [true, false, null]);
    });
  });

  group('scan failures', () {
    Future<Object?> firstError(Stream<BleAdvert> scan) async {
      final error = Completer<Object?>();
      final sub = scan.listen((_) {}, onError: error.complete);
      final result = await error.future;
      await sub.cancel();
      return result;
    }

    test('a scan without permission reports the permission error and never starts', () async {
      platform.granted = false;
      final error = await firstError(central.scan(services: [HueGatt.advertisedService]));
      expect((error as BleOperationException).kind, BleFailure.permissionDenied);
      expect(platform.scansStarted, 0);
    });

    test('a platform error when starting the scan is translated and logged', () async {
      platform.scanError = UniversalBleException(code: UniversalBleErrorCode.bluetoothNotEnabled, message: 'off');
      final error = await firstError(central.scan(services: [HueGatt.advertisedService]));
      expect((error as BleOperationException).kind, BleFailure.unavailable);
      expect(debugText(), contains('universal_ble error in startScan'));
    });
  });

  test('defaults to a memory log, an 800 ms retry and a 15 s connect timeout', () {
    final plain = UniversalBleCentral();
    expect(plain.retryDelay, const Duration(milliseconds: 800));
    expect(plain.connectTimeout, const Duration(seconds: 15));
    expect(plain.log.entries, isEmpty);
  });

  group('ensureReady', () {
    Future<BleOperationException?> failure({bool request = false}) => central
        .ensureReady(request: request)
        .then<BleOperationException?>((_) => null, onError: (Object e) => e as BleOperationException);

    test('asks for a missing permission on a user action and passes once granted', () async {
      platform
        ..granted = false
        ..grantOnRequest = true;
      expect(await failure(request: true), isNull);
      expect(platform.requests, 1);
      expect(debugText(), contains('permissions granted after'));
    });

    test('a refusal after a real prompt is denied this time only', () async {
      platform
        ..granted = false
        ..requestDelay = UniversalBleCentral.permanentDenialWithin + const Duration(milliseconds: 50);
      final error = await failure(request: true);
      expect(error!.kind, BleFailure.permissionDenied);
      expect(error.code, 'denied');
      expect(debugText(), contains('this time'));
    });

    test('an adapter that is off is unavailable, without asking to enable it unless asked to', () async {
      platform.availability = AvailabilityState.poweredOff;
      final error = await failure();
      expect(error!.kind, BleFailure.unavailable);
      expect(error.code, 'poweredOff');
      expect(platform.enables, 0);
    });

    test('on a user action it asks to turn Bluetooth on and passes once it is on', () async {
      platform
        ..availability = AvailabilityState.poweredOff
        ..afterEnable = AvailabilityState.poweredOn;
      expect(await failure(request: true), isNull);
      expect(platform.enables, 1);
      expect(debugText(), contains('adapter state after asking to enable poweredOn'));
    });

    test('a refused enable prompt leaves the adapter unavailable', () async {
      platform.availability = AvailabilityState.poweredOff;
      final error = await failure(request: true);
      expect(platform.enables, 1);
      expect(error!.kind, BleFailure.unavailable);
      expect(error.code, 'poweredOff');
    });

    test('an unauthorized adapter is a permission problem, an unsupported one unavailable', () async {
      platform.availability = AvailabilityState.unauthorized;
      final unauthorized = await failure();
      expect(unauthorized!.kind, BleFailure.permissionDenied);
      expect(unauthorized.code, 'unauthorized');
      platform.availability = AvailabilityState.unsupported;
      final unsupported = await failure();
      expect(unsupported!.kind, BleFailure.unavailable);
      expect(unsupported.code, 'unsupported');
    });
  });

  group('status', () {
    test('reports the adapter state and the permissions', () async {
      expect(await central.status(), {'Bluetooth': 'poweredOn', 'Permissions': 'granted'});
      platform
        ..granted = false
        ..availability = AvailabilityState.poweredOff;
      expect(await central.status(), {'Bluetooth': 'poweredOff', 'Permissions': 'not granted'});
    });

    test('a failing query reads as unknown with its error', () async {
      platform
        ..availabilityError = StateError('no adapter')
        ..permissionsError = StateError('no context');
      final status = await central.status();
      expect(status['Bluetooth'], 'unknown (Bad state: no adapter)');
      expect(status['Permissions'], 'unknown (Bad state: no context)');
    });
  });

  test('disconnect asks the platform and logs it', () async {
    await central.disconnect('AA:01');
    expect(platform.disconnects, ['AA:01']);
    expect(debugText(), contains('disconnect AA:01'));
  });

  test('a bond the platform accepts completes and is logged', () async {
    await central.pair('AA:01');
    expect(debugText(), contains('platform pair AA:01 ok'));
  });

  test('known devices still lists one source when the other fails', () async {
    bonded = [const BondedDevice(id: 'AA:01', name: 'Hue color lamp', type: 2)];
    platform.systemDevicesError = StateError('gatt down');
    expect((await central.knownDevices()).map((d) => d.deviceId), ['AA:01']);
    expect(debugText(), contains('error in getSystemDevices'));

    central = UniversalBleCentral(log: log, bondedDevices: () async => throw StateError('no channel'));
    platform
      ..systemDevicesError = null
      ..systemDevices = [
        BleDevice(deviceId: 'AA:04', name: null, services: [HueGatt.advertisedService]),
      ];
    final known = await central.knownDevices();
    expect(known.map((d) => d.deviceId), ['AA:04']);
    expect(known.single.name, '');
    expect(debugText(), contains('error in bondedDevices'));
  });

  group('reads, writes and the MTU', () {
    test('a write carries its value, with or without response', () async {
      await central.write('AA:01', HueGatt.lightService, HueGatt.power, Uint8List.fromList([1]));
      await central.write(
        'AA:01',
        HueGatt.lightService,
        HueGatt.control,
        Uint8List.fromList([2, 3]),
        withoutResponse: true,
      );
      expect(platform.writes, [
        (HueGatt.power, '1', BleOutputProperty.withResponse),
        (HueGatt.control, '2,3', BleOutputProperty.withoutResponse),
      ]);
    });

    test('a failed write on a dropped link is notConnected', () async {
      platform.writeError = UniversalBleException(code: UniversalBleErrorCode.deviceDisconnected, message: 'gone');
      final error = await central
          .write('AA:01', HueGatt.lightService, HueGatt.power, Uint8List.fromList([1]))
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((error as BleOperationException).kind, BleFailure.notConnected);
      expect(error.code, 'deviceDisconnected');
    });

    test('requestMtu returns what the link settled on', () async {
      platform.negotiatedMtu = 185;
      expect(await central.requestMtu('AA:01', 517), 185);
      expect(platform.mtuRequests, [517]);
    });

    test('a read returns the value', () async {
      expect(await central.read('AA:01', HueGatt.lightService, HueGatt.power), [1]);
    });
  });

  group('error translation', () {
    Future<BleOperationException> readFailure(Object error) async {
      platform.readErrors[HueGatt.power] = error;
      return central
          .read('AA:01', HueGatt.lightService, HueGatt.power)
          .then<BleOperationException>((_) => fail('read passed'), onError: (Object e) => e as BleOperationException);
    }

    test('an error that is not universal_ble keeps its text and type', () async {
      final error = await readFailure(StateError('channel closed'));
      expect(error.kind, BleFailure.other);
      expect(error.detail, 'Bad state: channel closed');
      expect(error.code, 'StateError');
      expect(debugText(), contains('error in read: StateError: Bad state: channel closed'));
    });

    test('platform details are added to the message unless they repeat it', () async {
      final withDetails = await readFailure(
        UniversalBleException(code: UniversalBleErrorCode.unknownError, message: 'failed', details: 'status 8'),
      );
      expect(withDetails.detail, 'failed (status 8)');
      final repeated = await readFailure(
        UniversalBleException(code: UniversalBleErrorCode.unknownError, message: 'failed', details: 'failed'),
      );
      expect(repeated.detail, 'failed');
    });

    test('GATT 133 in the text of an unknown error is unreachable', () async {
      final error = await readFailure(
        UniversalBleException(code: UniversalBleErrorCode.unknownError, message: 'GATT error 133'),
      );
      expect(error.kind, BleFailure.unreachable);
    });

    test('platform codes map to the failures the app explains', () async {
      final cases = {
        UniversalBleErrorCode.notPaired: BleFailure.unauthenticated,
        UniversalBleErrorCode.insufficientEncryption: BleFailure.unauthenticated,
        UniversalBleErrorCode.bluetoothNotAvailable: BleFailure.unavailable,
        UniversalBleErrorCode.bluetoothUnauthorized: BleFailure.permissionDenied,
        UniversalBleErrorCode.connectionTerminated: BleFailure.notConnected,
        UniversalBleErrorCode.connectionTimeout: BleFailure.timeout,
        UniversalBleErrorCode.connectionRejected: BleFailure.unreachable,
        UniversalBleErrorCode.connectionLimitExceeded: BleFailure.connectionLimit,
        UniversalBleErrorCode.unknownError: BleFailure.other,
      };
      for (final MapEntry(key: code, value: kind) in cases.entries) {
        final error = await readFailure(UniversalBleException(code: code, message: 'x'));
        expect(error.kind, kind, reason: code.name);
      }
    });
  });

  group('notifications', () {
    test('forwards the values the light sends and unsubscribes on cancel', () async {
      final values = <List<int>>[];
      final sub = central.notifications('AA:01', HueGatt.lightService, HueGatt.power).listen(values.add);
      while (platform.notifiable.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(platform.notifiable.single.$2, BleInputProperty.notification);
      platform.updateCharacteristicValue('AA:01', HueGatt.power, Uint8List.fromList([1]), null);
      platform.updateCharacteristicValue('AA:01', HueGatt.control, Uint8List.fromList([9]), null);
      platform.updateCharacteristicValue('AA:01', HueGatt.power, Uint8List.fromList([0]), null);
      await Future<void>.delayed(Duration.zero);
      expect(values, [
        [1],
        [0],
      ], reason: 'only the subscribed characteristic');
      await sub.cancel();
      expect(platform.notifiable.last.$2, BleInputProperty.disabled);
      expect(debugText(), contains('subscribe AA:01'));
    });

    test('a failed subscription is a translated stream error', () async {
      platform.subscribeError = UniversalBleException(
        code: UniversalBleErrorCode.characteristicNotFound,
        message: 'no such characteristic',
      );
      final error = Completer<Object>();
      final sub = central
          .notifications('AA:01', HueGatt.lightService, HueGatt.power)
          .listen((_) {}, onError: error.complete);
      expect(((await error.future) as BleOperationException).kind, BleFailure.notFound);
      await sub.cancel();
    });

    test('a failed unsubscribe on cancel is ignored', () async {
      platform.unsubscribeError = StateError('link gone');
      final sub = central.notifications('AA:01', HueGatt.lightService, HueGatt.power).listen((_) {});
      while (platform.notifiable.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await sub.cancel();
      expect(platform.notifiable.last.$2, BleInputProperty.disabled);
    });
  });

  test('connection changes report whether the link is up and log the platform error', () async {
    final changes = <bool>[];
    final sub = central.connectionChanges('AA:01').listen(changes.add);
    platform
      ..updateConnection('AA:01', true)
      ..updateConnection('AA:01', false, 'link lost', UniversalBleErrorCode.connectionTerminated, 8)
      ..updateConnection('AA:02', true);
    await Future<void>.delayed(Duration.zero);
    expect(changes, [true, false]);
    expect(debugText(), contains('connected false, error link lost, code connectionTerminated, native 8'));
    await sub.cancel();
  });
}
