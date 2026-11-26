// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/errors.dart';
import 'package:lumen/log/logger.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';
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
      proximitySettle: Duration.zero,
    );
  });

  String text() => log.entries.map((e) => e.message).join('\n');

  test('a new bulb bonds through the proximity handshake, without createBond', () async {
    final bulb = central.addBulb(SimulatedHueBulb(id: 'aa:01', commissioned: false));
    await driver.add('aa:01');
    final handshake = bulb.writes.first;
    expect(handshake.characteristic, HueGatt.proximity);
    expect(handshake.value, [0x01]);
    expect(handshake.withoutResponse, isTrue);
    expect(bulb.bonded, isTrue);
    expect(central.pairCalls, 0);
    expect(central.mtuRequests, [247]);
    expect(text(), contains('proximity flags 0x05'));
  });

  test('a bulb whose power-on window passed asks to switch it off and on', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01', pairingMode: false, windowExpired: true));
    final error = await driver.add('aa:01').then<Object?>((_) => null, onError: (Object e) => e);
    expect(error, isA<BondWindowExpired>());
    expect((error as LightError).message, contains('Switch the bulb off and on, then add it within a minute'));
    expect(text(), contains('proximity flags 0x08'));
    expect(central.pairCalls, 0);
  });

  test('a bulb that is not open says how to make it discoverable, and mentions its bridge', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01', pairingMode: false, onBridge: true));
    final error = await driver.add('aa:01').then<Object?>((_) => null, onError: (Object e) => e);
    expect(error, isA<NotInPairingMode>());
    expect((error as LightError).message, contains('Hue Bridge'));
    expect(error.message, contains('Make discoverable'));
  });

  test('falls back to createBond when the encrypted read does not bond', () async {
    final bulb = central.addBulb(SimulatedHueBulb(id: 'aa:01', bondsOnRead: false));
    await driver.add('aa:01');
    expect(central.pairCalls, 1);
    expect(bulb.bonded, isTrue);
    expect(text(), contains('falling back to pair'));
  });

  test('a bulb without the proximity characteristic pairs the old way', () async {
    final bulb = central.addBulb(SimulatedHueBulb(id: 'aa:01', proximitySupported: false));
    await driver.add('aa:01');
    expect(bulb.bonded, isTrue);
    expect(text(), contains('no proximity handshake'));
  });

  test('the whole pairing attempt gives up after the pairing timeout', () async {
    central = SimulatedBleCentral(scanDelay: Duration.zero, latency: const Duration(milliseconds: 100));
    driver = HueBleDriver(central, log: log, pairingTimeout: const Duration(milliseconds: 50));
    central.addBulb(SimulatedHueBulb(id: 'aa:01'));
    await expectLater(driver.add('aa:01'), throwsA(isA<PairingTimedOut>()));
  });

  test('make discoverable writes 0x01 with response to 2004 and opens the bulb', () async {
    final bulb = central.addBulb(SimulatedHueBulb(id: 'aa:01'));
    await driver.add('aa:01');
    bulb.pairingMode = false;
    await driver.makeDiscoverable('aa:01');
    final write = bulb.writes.last;
    expect(write.characteristic, HueGatt.makeDiscoverable);
    expect(write.value, [0x01]);
    expect(write.withoutResponse, isFalse);
    expect(bulb.openForBonding, isTrue);
  });

  test('a bulb that refuses make discoverable gets a clear message', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01', refusesDiscoverable: true));
    await driver.add('aa:01');
    await expectLater(driver.makeDiscoverable('aa:01'), throwsA(isA<DiscoverableRefused>()));
  });

  test('scan results carry whether the bulb is open for bonding', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa:01'));
    central.addBulb(SimulatedHueBulb(id: 'aa:02', pairingMode: false));
    final found = await driver.discover().take(2).toList();
    expect({for (final b in found) b.deviceId: b.openForBonding}, {'aa:01': true, 'aa:02': false});
  });
}
