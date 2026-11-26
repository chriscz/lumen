// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/errors.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/ble/ble_central.dart';

/// A phone whose adapter can fail for a reason that is not a lasting issue.
class _BusyCentral extends SimulatedBleCentral {
  _BusyCentral() : super(scanDelay: Duration.zero);

  BleOperationException? notReady;

  @override
  Future<void> ensureReady({bool request = false}) async {
    if (notReady case final e?) throw e;
    return super.ensureReady(request: request);
  }
}

void main() {
  late _BusyCentral central;
  late MemoryHomeStore store;
  late HomeController home;

  HomeController build() =>
      HomeController(AppServices.simulated(central: central, bridge: SimulatedBridge(), store: store));

  setUp(() async {
    central = _BusyCentral();
    store = MemoryHomeStore();
    home = build();
    expect(home.loaded, isFalse);
    await home.load();
    expect(home.loaded, isTrue);
  });

  const busy = BleOperationException(BleFailure.other, 'adapter busy', 'busy');

  group('prepareBluetooth', () {
    test('asks for the permission once per launch and shows the issue every time', () async {
      central.permissionGranted = false;
      expect(await home.prepareBluetooth(), isFalse);
      expect(central.permissionRequests, 1);
      expect(home.bluetoothIssue, isA<BluetoothPermissionDenied>());
      final seq = home.bluetoothIssueSeq;

      expect(await home.prepareBluetooth(), isFalse);
      expect(central.permissionRequests, 1, reason: 'a denied prompt never comes back on its own');
      expect(home.bluetoothIssueSeq, seq + 1, reason: 'opening Add light again shows the issue again');
    });

    test('Bluetooth that is off is an issue too, cleared once it is on', () async {
      central.available = false;
      expect(await home.prepareBluetooth(), isFalse);
      expect(home.bluetoothIssue, isA<BluetoothUnavailable>());

      central.available = true;
      expect(await home.prepareBluetooth(), isTrue);
      expect(home.bluetoothIssue, isNull);
    });

    test('another Bluetooth failure is thrown to the caller, not kept as an issue', () async {
      central.notReady = busy;
      await expectLater(home.prepareBluetooth(), throwsA(isA<BluetoothError>()));
      expect(home.bluetoothIssue, isNull);
    });
  });

  group('retryBluetooth', () {
    test('asks again each time, even after the launch asked already', () async {
      central.permissionGranted = false;
      await home.prepareBluetooth();
      expect(await home.retryBluetooth(), isFalse);
      expect(await home.retryBluetooth(), isFalse);
      expect(central.permissionRequests, 3);
      expect(home.bluetoothIssue, isA<BluetoothPermissionDenied>());
    });

    test('once it works, clears the issue and probes the bulbs', () async {
      final bulb = central.addBulb(SimulatedHueBulb(id: 'aa', name: 'Desk'));
      final light = await home.addBluetoothLight(await home.scanBluetooth().first);
      central.permissionGranted = false;
      await home.connectAll();
      expect(home.light(light.id)!.reachable, isFalse);
      expect(home.bluetoothIssue, isNotNull);

      central.permissionGranted = true;
      bulb.changeLocally(const LightCommand(on: true));
      expect(await home.retryBluetooth(), isTrue);
      expect(home.bluetoothIssue, isNull);
      expect(home.light(light.id)!.reachable, isTrue);
      expect(home.light(light.id)!.isOn, isTrue, reason: 'the probe read the bulb');
    });

    test('a failure that is not a lasting issue clears the issue shown', () async {
      central.permissionGranted = false;
      await home.prepareBluetooth();
      central
        ..permissionGranted = true
        ..notReady = busy;
      expect(await home.retryBluetooth(), isFalse);
      expect(home.bluetoothIssue, isNull);
    });
  });

  test('known bulbs lists the bonded bulbs that are not added yet', () async {
    central
      ..addBulb(SimulatedHueBulb(id: 'aa', name: 'Desk', bonded: true))
      ..addBulb(SimulatedHueBulb(id: 'bb', name: 'Bedside', bonded: true))
      ..addBulb(SimulatedHueBulb(id: 'cc', name: 'Stranger'));
    await home.addBluetoothLight((await home.knownBluetooth()).firstWhere((b) => b.deviceId == 'aa'));
    expect((await home.knownBluetooth()).map((b) => b.deviceId), ['bb']);
  });

  test('a bulb that cannot be added is logged and the error passed on, with nothing added', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa', name: 'Shy', pairingMode: false));
    final found = await home.scanBluetooth().first;
    await expectLater(home.addBluetoothLight(found), throwsA(isA<LightError>()));
    expect(home.lights, isEmpty);
    expect(home.log.entries.map((e) => e.message), contains(startsWith('adding aa failed: ')));
  });

  test('dispose stops listening and closes the error stream', () async {
    final bulb = central.addBulb(SimulatedHueBulb(id: 'aa', name: 'Desk'));
    await home.addBluetoothLight(await home.scanBluetooth().first);
    final closed = home.errors.isEmpty;
    home.dispose();
    expect(await closed, isTrue, reason: 'the stream ends without an error');
    // A report after dispose would otherwise notify a disposed controller,
    // which fails the test as an uncaught error.
    bulb.report(const LightState(on: true));
    await Future<void>.delayed(Duration.zero);
    expect(home.lights.single.isOn, isFalse, reason: 'the report was not taken');
  });
}
