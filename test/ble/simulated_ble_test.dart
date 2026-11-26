// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/transport/ble/ble_central.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';

void main() {
  Matcher failsWith(BleFailure kind, [String? code]) => throwsA(
    isA<BleOperationException>().having((e) => e.kind, 'kind', kind).having((e) => e.code, 'code', code ?? anything),
  );

  Uint8List bytes(List<int> b) => Uint8List.fromList(b);

  test('a recorded write describes itself', () {
    expect(GattWrite(HueGatt.power, bytes([1])).toString(), 'GattWrite(${HueGatt.power}, [1])');
    expect(
      GattWrite(HueGatt.proximity, bytes([1]), withoutResponse: true).toString(),
      'GattWrite(${HueGatt.proximity}, [1], without response)',
    );
  });

  group('the simulated bulb', () {
    test('a characteristic it does not have is notFound for reads and writes', () {
      final bulb = SimulatedHueBulb.minimal(id: 'aa:01', bonded: true);
      expect(() => bulb.read(HueGatt.capabilities), failsWith(BleFailure.notFound, 'characteristicNotFound'));
      expect(() => bulb.write(HueGatt.identify, bytes([1])), failsWith(BleFailure.notFound));
      expect(bulb.reads, isEmpty);
    });

    test('the temperature of a light showing an xy colour reads as unset', () {
      final bulb = SimulatedHueBulb(
        id: 'aa:01',
        bonded: true,
        state: const LightState(on: true, color: XyColor(0.6, 0.3)),
      );
      expect(bulb.read(HueGatt.temperature), [0xFF, 0xFF]);
    });

    test('single-value writes change the power, brightness and colour', () {
      final bulb = SimulatedHueBulb(id: 'aa:01', bonded: true);
      bulb
        ..write(HueGatt.power, HueBleCodec.encodePower(true))
        ..write(HueGatt.brightness, HueBleCodec.encodeBrightness(90))
        ..write(HueGatt.temperature, HueBleCodec.encodeMireds(300));
      expect(bulb.state.on, isTrue);
      expect(bulb.state.brightness, 90);
      expect(bulb.state.color, const WhiteColor(300));
      bulb.write(HueGatt.xy, HueBleCodec.encodeXy(const XyColor(0.6, 0.3)));
      expect(bulb.state.color, const XyColor(0.6, 0.3));
      expect(bulb.writes.map((w) => w.characteristic), [
        HueGatt.power,
        HueGatt.brightness,
        HueGatt.temperature,
        HueGatt.xy,
      ]);
    });

    test('each write reports the new state', () async {
      final bulb = SimulatedHueBulb(id: 'aa:01', bonded: true);
      final reports = <LightState>[];
      bulb.reports.listen((r) => reports.add(HueBleCodec.decodeControl(r)));
      bulb.write(HueGatt.power, HueBleCodec.encodePower(true));
      expect(reports.single.on, isTrue);
    });

    test('a colour the light kind cannot show is ignored', () {
      final white = SimulatedHueBulb(id: 'aa:01', model: 'LWA001', bonded: true);
      white.write(HueGatt.temperature, HueBleCodec.encodeMireds(200));
      expect(white.state.color, const WhiteColor(366));
      final ambiance = SimulatedHueBulb(id: 'aa:02', model: 'LTA001', bonded: true);
      ambiance.write(HueGatt.xy, HueBleCodec.encodeXy(const XyColor(0.6, 0.3)));
      expect(ambiance.state.color, const WhiteColor(366));
    });

    test('a name longer than 32 bytes is refused and not recorded', () {
      final bulb = SimulatedHueBulb(id: 'aa:01', name: 'Desk', bonded: true);
      expect(
        () => bulb.write(HueGatt.name, bytes(List.filled(33, 0x41))),
        failsWith(BleFailure.other, 'invalidAttributeLength'),
      );
      expect(bulb.name, 'Desk');
      expect(bulb.writes, isEmpty);
    });

    test('a minimum dim level outside 1 to 254, or without response, is refused', () {
      final bulb = SimulatedHueBulb(id: 'aa:01', bonded: true);
      for (final (value, withoutResponse) in [
        ([0], false),
        ([255], false),
        ([1, 2], false),
        ([10], true),
      ]) {
        expect(
          () => bulb.write(HueGatt.minDim, bytes(value), withoutResponse: withoutResponse),
          failsWith(BleFailure.other, 'writeNotPermitted'),
          reason: '$value',
        );
      }
      expect(bulb.minDim, [0x01]);
      expect(bulb.writes, isEmpty);
      bulb.write(HueGatt.minDim, bytes([10]));
      expect(bulb.minDim, [10]);
    });

    test('a characteristic that takes no writes refuses them', () {
      final bulb = SimulatedHueBulb(id: 'aa:01', bonded: true);
      expect(() => bulb.write(HueGatt.model, bytes([0x41])), failsWith(BleFailure.other, 'writeNotPermitted'));
      expect(bulb.writes, isEmpty);
    });
  });

  group('the simulated central', () {
    test('without permission it is denied, for good only once Android stops asking', () async {
      final central = SimulatedBleCentral(permissionGranted: false);
      await expectLater(central.ensureReady(), failsWith(BleFailure.permissionDenied, 'notGranted'));
      await expectLater(central.ensureReady(request: true), failsWith(BleFailure.permissionDenied, 'notGranted'));
      expect(central.permissionRequests, 1);
      central.permanentlyDenied = true;
      await expectLater(
        central.ensureReady(request: true),
        failsWith(BleFailure.permissionDenied, 'permanentlyDenied'),
      );
      expect(central.permissionRequests, 1, reason: 'no prompt once denied for good');
    });

    test('status reports the adapter and the permission', () async {
      final central = SimulatedBleCentral();
      expect(await central.status(), {'Bluetooth': 'poweredOn', 'Permissions': 'granted'});
      central
        ..available = false
        ..permissionGranted = false;
      expect(await central.status(), {'Bluetooth': 'poweredOff', 'Permissions': 'not granted'});
    });

    test('a scan with Bluetooth off fails and never starts', () async {
      final central = SimulatedBleCentral(available: false, scanDelay: Duration.zero);
      await expectLater(
        central.scan(services: [HueGatt.advertisedService]),
        emitsError(isA<BleOperationException>().having((e) => e.kind, 'kind', BleFailure.unavailable)),
      );
      expect(central.scans, 0);
    });
  });
}
