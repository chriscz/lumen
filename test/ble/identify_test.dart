// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/errors.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/ble/ble_central.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';
import 'package:lumen/transport/ble/hue_ble_driver.dart';

void main() {
  late SimulatedBleCentral central;

  setUp(() => central = SimulatedBleCentral(scanDelay: Duration.zero));

  test('knows the identify characteristic', () {
    expect(HueGatt.identify, '932c32bd-0006-47a2-835a-a8d455b859dd');
  });

  test('identify writes the blink command 0x01 with response to 0006 (spec 4.3, 5.3)', () async {
    final driver = HueBleDriver(central);
    final bulb = central.addBulb(SimulatedHueBulb(id: 'a'));
    await driver.add('a');
    await driver.identify('a');
    final write = bulb.writes.last;
    expect(write.characteristic, HueGatt.identify);
    expect(write.value, [0x01]);
    expect(write.withoutResponse, isFalse);
    expect(bulb.identifies, 1);
  });

  test('identify on a bulb without 0006 fails', () async {
    final driver = HueBleDriver(central);
    central.addBulb(SimulatedHueBulb(id: 'a', identifySupported: false));
    await driver.add('a');
    await expectLater(driver.identify('a'), throwsA(isA<LightError>()));
  });

  group('controller', () {
    late HomeController home;

    setUp(() async {
      home = HomeController(
        AppServices.simulated(central: central, bridge: SimulatedBridge(), store: MemoryHomeStore()),
      );
      await home.load();
    });

    Future<SimulatedHueBulb> add(SimulatedHueBulb bulb) async {
      central.addBulb(bulb);
      await home.addBluetoothLight(await home.scanBluetooth().firstWhere((b) => b.deviceId == bulb.id));
      return bulb;
    }

    test('identifies a bulb with one blink command', () async {
      final bulb = await add(SimulatedHueBulb(id: 'a'));
      final before = bulb.writes.length;
      await home.identify('ble:a', step: Duration.zero);
      expect(bulb.writes.skip(before).map((w) => w.characteristic), [HueGatt.identify]);
    });

    test('falls back to blinking the power when the light has no identify characteristic', () async {
      final bulb = await add(SimulatedHueBulb(id: 'a', identifySupported: false));
      final before = bulb.writes.length;
      await home.identify('ble:a', step: Duration.zero);
      expect(bulb.writes.skip(before).map((w) => w.characteristic), List.filled(4, HueGatt.control));
    });

    test('an identify that fails for another reason is reported, not blinked', () async {
      final bulb = await add(SimulatedHueBulb(id: 'a'));
      bulb.refuseWrite = (c, _) =>
          c == HueGatt.identify ? const BleOperationException(BleFailure.timeout, 'no answer', 'timeout') : null;
      final errors = <LightError>[];
      final sub = home.errors.listen(errors.add);
      final before = bulb.writes.length;
      await home.identify('ble:a', step: Duration.zero);
      await pumpEventQueue();
      expect(bulb.writes.skip(before), isEmpty);
      expect(errors.single, isA<LightUnreachable>());
      await sub.cancel();
    });

    test('a light with Hue extra security is reported, not blinked', () async {
      final bulb = await add(SimulatedHueBulb(id: 'a'));
      bulb.appSecurity = true;
      await home.identify('ble:a', step: Duration.zero);
      expect(home.needsAppSecurity('ble:a'), isTrue);
      expect(bulb.writes.where((w) => w.characteristic == HueGatt.control), isEmpty);
    });

    test('a power blink that fails part way restores the power the light had', () async {
      final bulb = await add(SimulatedHueBulb(id: 'a', identifySupported: false));
      expect(bulb.state.on, isFalse);
      var controlWrites = 0;
      bulb.refuseWrite = (c, _) {
        if (c != HueGatt.control) return null;
        controlWrites++;
        return controlWrites == 2 ? const BleOperationException(BleFailure.timeout, 'no answer', 'timeout') : null;
      };
      await home.identify('ble:a', step: Duration.zero);
      await pumpEventQueue();
      expect(bulb.state.on, isFalse, reason: 'the light ends as it was, not inverted');
      expect(home.light('ble:a')!.state.on, isFalse);
    });

    test('when the power cannot be restored the app shows the power the light was left with', () async {
      final bulb = await add(SimulatedHueBulb(id: 'a', identifySupported: false));
      var controlWrites = 0;
      bulb.refuseWrite = (c, _) {
        if (c != HueGatt.control) return null;
        controlWrites++;
        return controlWrites >= 2 ? const BleOperationException(BleFailure.timeout, 'no answer', 'timeout') : null;
      };
      await home.identify('ble:a', step: Duration.zero);
      await pumpEventQueue();
      expect(bulb.state.on, isTrue);
      expect(home.light('ble:a')!.state.on, isTrue);
    });
  });
}
