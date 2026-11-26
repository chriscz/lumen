// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/errors.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/log/logger.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/transport/ble/ble_central.dart';
import 'package:lumen/transport/ble/hue_ble_driver.dart';

void main() {
  late SimulatedBleCentral central;
  late Logger log;
  late HueBleDriver driver;

  setUp(() {
    central = SimulatedBleCentral(scanDelay: Duration.zero);
    log = Logger.memory()..debugEnabled = true;
    driver = HueBleDriver(
      central,
      log: log,
      bondTimeout: const Duration(milliseconds: 40),
      bondPoll: const Duration(milliseconds: 10),
    );
  });

  String debugText() => log.entries.where((e) => e.level == LogLevel.debug).map((e) => e.message).join('\n');

  test('when pair fails, an encrypted read starts the bond and the bulb is added', () async {
    final bulb = central.addBulb(SimulatedHueBulb(id: 'aa:01', name: 'Desk', proximitySupported: false));
    central.pairError = const BleOperationException(BleFailure.other, 'createBond returned false', 'pairingFailed');
    final info = await driver.add('aa:01');
    expect(bulb.bonded, isTrue);
    expect(info.name, 'Desk');
    final text = debugText();
    expect(text, contains('pair aa:01 failed'));
    expect(text, contains('createBond returned false'));
    expect(text, contains('reading control to start bonding'));
    expect(text, contains('bonded aa:01'));
  });

  test('a bulb that is not in pairing mode fails after the fallback, with debug entries', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01', pairingMode: false, proximitySupported: false));
    central.pairError = const BleOperationException(BleFailure.unauthenticated, 'bond rejected', 'pairingFailed');
    await expectLater(driver.add('aa:01'), throwsA(isA<NotInPairingMode>()));
    final text = debugText();
    expect(text, contains('connect aa:01'));
    expect(text, contains('pair aa:01 failed'));
    expect(text, contains('bond rejected'));
    expect(text, contains('reading control to start bonding'));
    expect(text, contains('not bonded'));
    expect(log.entries.where((e) => e.level == LogLevel.warning).map((e) => e.message).join(), contains('aa:01'));
  });

  test('a bulb already bonded with this phone skips pairing', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01', bondedElsewhere: true));
    await driver.add('aa:01');
    expect(central.pairCalls, 0);
    expect(debugText(), contains('isPaired aa:01: true'));
  });

  test('a connect timeout while adding means the bulb is held by another device', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01'));
    central.connectErrors.add(const BleOperationException(BleFailure.timeout, 'connect timed out'));
    await expectLater(driver.add('aa:01'), throwsA(isA<BulbBusy>()));
  });

  test('an unknown failure keeps the raw code for the details', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01'));
    central.connectErrors.add(const BleOperationException(BleFailure.other, 'Unknown Error 8', 'unknownError'));
    final error = await driver.add('aa:01').then<Object?>((_) => null, onError: (Object e) => e);
    expect(error, isA<BluetoothError>());
    expect((error as BluetoothError).message, contains('unknownError'));
    expect(error.details, contains('Unknown Error 8'));
  });

  test('Bluetooth off and a missing permission keep their own messages', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01'));
    central.connectErrors.add(const BleOperationException(BleFailure.unavailable));
    await expectLater(driver.add('aa:01'), throwsA(isA<BluetoothUnavailable>()));
    central.connectErrors.add(const BleOperationException(BleFailure.permissionDenied));
    await expectLater(driver.add('aa:01'), throwsA(isA<BluetoothPermissionDenied>()));
  });

  test('lists bulbs bonded with this phone that do not advertise', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01', name: 'Hall', bondedElsewhere: true));
    central.addBulb(SimulatedHueBulb(id: 'aa:02', name: 'New'));
    final known = await driver.knownBulbs();
    expect(known.map((b) => b.deviceId), ['aa:01']);
    final scanned = await driver.discover().take(1).toList();
    expect(scanned.single.deviceId, 'aa:02');
  });

  test('logs reads and writes with hex bytes in debug mode', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01'));
    await driver.add('aa:01');
    await driver.send('aa:01', const LightCommand(on: true));
    final text = debugText();
    expect(text, contains('write aa:01 932c32bd-0007'));
    expect(text, contains('01 01 01'));
    // State comes from the combined control characteristic (docs/protocol.md),
    // not from single-value characteristic 932c32bd-0002.
    expect(text, contains('read aa:01 932c32bd-0001'));
    expect(text, isNot(contains('read aa:01 932c32bd-0002')));
  });

  test('logs nothing below info when debug logging is off', () async {
    log.debugEnabled = false;
    central.addBulb(SimulatedHueBulb(id: 'aa:01'));
    await driver.add('aa:01');
    expect(log.entries.where((e) => e.level == LogLevel.debug), isEmpty);
    expect(log.entries.map((e) => e.message).join(), contains('added aa:01'));
  });
}
