// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/errors.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/log/logger.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/transport/ble/ble_central.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';
import 'package:lumen/transport/ble/hue_ble_driver.dart';

/// The simulated central with the platform failures a real phone shows:
/// reads, bond queries, characteristic probes, MTU requests and the bonded
/// device list that fail on their own.
class FaultyCentral extends SimulatedBleCentral {
  FaultyCentral() : super(scanDelay: Duration.zero);

  /// Errors that reads of a characteristic fail with.
  final Map<String, BleOperationException> readErrors = {};
  BleOperationException? isPairedError;
  BleOperationException? hasCharacteristicError;
  BleOperationException? mtuError;
  BleOperationException? knownDevicesError;

  @override
  Future<Uint8List> read(String deviceId, String service, String characteristic) async {
    if (readErrors[characteristic] case final e?) {
      readRequests.add((deviceId, characteristic));
      throw e;
    }
    return super.read(deviceId, service, characteristic);
  }

  @override
  Future<bool?> isPaired(String deviceId) async {
    if (isPairedError case final e?) throw e;
    return super.isPaired(deviceId);
  }

  @override
  Future<bool> hasCharacteristic(String deviceId, String service, String characteristic) async {
    if (hasCharacteristicError case final e?) throw e;
    return super.hasCharacteristic(deviceId, service, characteristic);
  }

  @override
  Future<int> requestMtu(String deviceId, int mtu) async {
    if (mtuError case final e?) throw e;
    return super.requestMtu(deviceId, mtu);
  }

  @override
  Future<List<BleAdvert>> knownDevices() async {
    if (knownDevicesError case final e?) throw e;
    return super.knownDevices();
  }
}

void main() {
  const other = BleOperationException(BleFailure.other, 'gatt status 6', 'requestNotSupported');
  late FaultyCentral central;
  late Logger log;
  late HueBleDriver driver;

  setUp(() {
    central = FaultyCentral();
    log = Logger.memory()..debugEnabled = true;
    driver = HueBleDriver(central, log: log, proximitySettle: Duration.zero);
  });

  String logText() => log.entries.map((e) => e.message).join('\n');

  test('connected tracks each connect and each drop', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01', bonded: true));
    await driver.readState('aa:01');
    expect(driver.connected, {'aa:01'});
    central.dropConnection('aa:01');
    await Future<void>.delayed(Duration.zero);
    expect(driver.connected, isEmpty);
  });

  test('a scan without permission fails with the permission error', () async {
    central.permissionGranted = false;
    await expectLater(driver.discover(), emitsError(isA<BluetoothPermissionDenied>()));
    expect(logText(), contains('scan failed'));
  });

  test('a failed list of known devices is an empty list, not an error', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01', bonded: true));
    central.knownDevicesError = other;
    expect(await driver.knownBulbs(), isEmpty);
    expect(logText(), contains('listing known devices failed'));
  });

  group('adding a bulb', () {
    test('logs whether the bulb has a security key set', () async {
      central.addBulb(SimulatedHueBulb(id: 'aa:01', securityKey: SimulatedHueBulb.emptyKey));
      central.addBulb(SimulatedHueBulb(id: 'aa:02', securityKey: SimulatedHueBulb.provisionedKey));
      await driver.add('aa:01');
      await expectLater(driver.add('aa:02'), throwsA(isA<NeedsAppSecurity>()));
      expect(logText(), allOf(contains('security key on aa:01: not set'), contains('security key on aa:02: set')));
    });

    test('a security key that cannot be read counts as not set', () async {
      central.addBulb(SimulatedHueBulb(id: 'aa:01', securityKey: SimulatedHueBulb.provisionedKey));
      central.readErrors[HueGatt.securityKey] = other;
      final info = await driver.add('aa:01');
      expect(info.deviceId, 'aa:01');
      expect(logText(), contains('no security key characteristic on aa:01'));
    });

    test('capabilities that cannot be read fall back to the model number', () async {
      central.addBulb(SimulatedHueBulb(id: 'aa:01', model: 'LTA001'));
      central.readErrors[HueGatt.capabilities] = other;
      final info = await driver.add('aa:01');
      expect(info.capabilities, isNull);
      expect(info.kind, LightKind.ambiance);
    });

    test('a bond query that fails is no bond: the proximity handshake and encrypted read still bond', () async {
      final bulb = central.addBulb(SimulatedHueBulb(id: 'aa:01'));
      central.isPairedError = other;
      await driver.add('aa:01');
      expect(bulb.bonded, isTrue);
      expect(central.pairCalls, 0, reason: 'the read bonded it, so pair was not needed');
      expect(logText(), contains('isPaired aa:01 failed'));
    });

    test('a proximity handshake that fails falls back to pair', () async {
      final bulb = central.addBulb(SimulatedHueBulb(id: 'aa:01'));
      bulb.refuseWrite = (characteristic, _) => characteristic == HueGatt.proximity ? other : null;
      await driver.add('aa:01');
      expect(bulb.bonded, isTrue);
      expect(central.pairCalls, 1);
      expect(central.mtuRequests, isEmpty, reason: 'the MTU is asked only after the handshake');
      expect(logText(), contains('no proximity handshake on aa:01'));
    });

    test('a refused MTU request does not stop the bond', () async {
      final bulb = central.addBulb(SimulatedHueBulb(id: 'aa:01'));
      central.mtuError = other;
      await driver.add('aa:01');
      expect(bulb.bonded, isTrue);
      expect(logText(), contains('mtu request aa:01 failed'));
    });

    test('a name that cannot be read is the default name', () async {
      central.addBulb(SimulatedHueBulb(id: 'aa:01', name: 'Desk'));
      central.readErrors[HueGatt.name] = other;
      expect((await driver.add('aa:01')).name, 'Hue bulb');
    });

    test('a name read on a link that dropped fails the add', () async {
      central.addBulb(SimulatedHueBulb(id: 'aa:01', name: 'Desk'));
      central.readErrors[HueGatt.name] = const BleOperationException(BleFailure.notConnected);
      await expectLater(driver.add('aa:01'), throwsA(isA<LightUnreachable>()));
    });
  });

  test('a characteristic probe that fails counts as present, and the read then tells', () async {
    central.addBulb(SimulatedHueBulb.minimal(id: 'aa:01', bonded: true));
    central.hasCharacteristicError = other;
    final features = await driver.readFeatures('aa:01');
    expect(features.capabilities, isNull);
    expect(features.powerOn, isFalse);
    expect(features.minDim, isTrue, reason: 'write-only, so only the probe can tell');
    expect(logText(), contains('hasCharacteristic aa:01'));
  });

  test('a protected write refused while the bond query fails keeps the original error', () async {
    final bulb = central.addBulb(SimulatedHueBulb(id: 'aa:01', bonded: true));
    bulb.refuseWrite = (characteristic, _) => characteristic == HueGatt.name
        ? const BleOperationException(BleFailure.unauthenticated, 'insufficient authentication')
        : null;
    await driver.readState('aa:01');
    central.isPairedError = other;
    await expectLater(driver.rename('aa:01', 'Desk'), throwsA(isA<NotInPairingMode>()));
    expect(logText(), contains('isPaired aa:01 failed'));
  });

  group('reading the state from single values', () {
    const red = XyColor(0.68, 0.31);

    test('falls back to the colour temperature when xy cannot be read', () async {
      central.addBulb(
        SimulatedHueBulb(
          id: 'aa:01',
          bonded: true,
          controlReadable: false,
          state: const LightState(on: true, brightness: 80, color: WhiteColor(250)),
        ),
      );
      central.readErrors[HueGatt.xy] = other;
      expect(await driver.readState('aa:01'), const LightState(on: true, brightness: 80, color: WhiteColor(250)));
    });

    test('has no colour when neither xy nor the temperature can be read', () async {
      central.addBulb(
        SimulatedHueBulb(
          id: 'aa:01',
          bonded: true,
          controlReadable: false,
          state: const LightState(on: true, brightness: 80, color: red),
        ),
      );
      central.readErrors[HueGatt.xy] = other;
      central.readErrors[HueGatt.temperature] = other;
      expect(await driver.readState('aa:01'), const LightState(on: true, brightness: 80));
    });

    test('a missing power characteristic without a platform code is CharacteristicMissing', () async {
      central.addBulb(SimulatedHueBulb(id: 'aa:01', bonded: true, controlReadable: false));
      central.readErrors[HueGatt.power] = const BleOperationException(BleFailure.notFound, 'gone');
      final error = await driver.readState('aa:01').then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<CharacteristicMissing>());
      expect((error as CharacteristicMissing).details, 'notFound: gone');
    });
  });
}
