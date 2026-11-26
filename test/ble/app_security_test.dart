// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/errors.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';
import 'package:lumen/transport/ble/hue_ble_driver.dart';

void main() {
  const message = "This light uses Hue's extra security and needs the official app or a Hue Bridge.";

  group('security indicator 97fe6561-2005 (spec 3.3)', () {
    test('knows the characteristic', () {
      expect(HueGatt.securityKey, '97fe6561-2005-4f62-86e9-b71ee2da3d22');
    });

    test('an entry with a non-zero value means a key is set', () {
      expect(HueBleCodec.securityKeySet(Uint8List.fromList([0x00, 0x02, 0x00, 0x07])), isTrue);
    });

    test('empty or all-zero entries mean no key', () {
      expect(HueBleCodec.securityKeySet(Uint8List(0)), isFalse);
      expect(HueBleCodec.securityKeySet(Uint8List.fromList([0x00, 0x00])), isFalse);
      expect(HueBleCodec.securityKeySet(Uint8List.fromList([0x00, 0x04, 0, 0, 0, 0, 0x01, 0x01, 0])), isFalse);
    });
  });

  group('driver', () {
    late SimulatedBleCentral central;
    late HueBleDriver driver;

    setUp(() {
      central = SimulatedBleCentral(scanDelay: Duration.zero);
      driver = HueBleDriver(central);
    });

    test('the message says what to do', () {
      expect(const NeedsAppSecurity().message, message);
    });

    test('a light that reports a security key is refused with a clear message', () async {
      central.addBulb(SimulatedHueBulb(id: 'a', securityKey: SimulatedHueBulb.provisionedKey));
      await expectLater(driver.add('a'), throwsA(isA<NeedsAppSecurity>()));
    });

    test('a light with the characteristic but no key set is added', () async {
      central.addBulb(SimulatedHueBulb(id: 'a', securityKey: SimulatedHueBulb.emptyKey));
      expect((await driver.add('a')).name, isNotEmpty);
    });

    test('a light that refuses protected access after bonding is refused too', () async {
      final bulb = central.addBulb(SimulatedHueBulb(id: 'a', appSecurity: true));
      await expectLater(driver.add('a'), throwsA(isA<NeedsAppSecurity>()));
      expect(bulb.bonded, isTrue, reason: 'the bond itself worked');
    });

    test('a refused control write on a bonded light means extra security', () async {
      final bulb = central.addBulb(SimulatedHueBulb(id: 'a'));
      await driver.add('a');
      bulb.appSecurity = true;
      await expectLater(driver.send('a', const LightCommand(on: true)), throwsA(isA<NeedsAppSecurity>()));
      await expectLater(driver.rename('a', 'Hall'), throwsA(isA<NeedsAppSecurity>()));
    });

    test('a refusal before bonding is still the pairing error', () async {
      central.addBulb(SimulatedHueBulb(id: 'a', pairingMode: false, appSecurity: true));
      await expectLater(driver.add('a'), throwsA(isA<NotInPairingMode>()));
    });
  });

  group('controller', () {
    test('a light that starts refusing writes shows the message and is marked', () async {
      final central = SimulatedBleCentral(scanDelay: Duration.zero);
      final home = HomeController(
        AppServices.simulated(central: central, bridge: SimulatedBridge(), store: MemoryHomeStore()),
      );
      await home.load();
      final bulb = central.addBulb(SimulatedHueBulb(id: 'a'));
      await home.addBluetoothLight(await home.scanBluetooth().first);
      final errors = <LightError>[];
      home.errors.listen(errors.add);
      bulb.appSecurity = true;
      await home.setPower('ble:a', true);
      await Future<void>.delayed(Duration.zero);
      expect(errors.single.message, message);
      expect(home.needsAppSecurity('ble:a'), isTrue);
    });
  });
}
