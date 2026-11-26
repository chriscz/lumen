// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/transport/ble/ble_uuid.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';

void main() {
  test('lowercases a full UUID', () {
    expect(BleUuid.normalize('0000FE0F-0000-1000-8000-00805F9B34FB'), HueGatt.advertisedService);
    expect(BleUuid.normalize('932C32BD-0000-47A2-835A-A8D455B859DD'), HueGatt.lightService);
  });

  test('expands 16-bit and 32-bit short forms to the Bluetooth base UUID', () {
    expect(BleUuid.normalize('fe0f'), HueGatt.advertisedService);
    expect(BleUuid.normalize('FE0F'), HueGatt.advertisedService);
    expect(BleUuid.normalize('0000fe0f'), HueGatt.advertisedService);
    expect(BleUuid.normalize('180A'), HueGatt.deviceInfoService);
  });

  test('ignores braces and surrounding space', () {
    expect(BleUuid.normalize(' {0000FE0F-0000-1000-8000-00805F9B34FB} '), HueGatt.advertisedService);
  });

  test('compares any two forms', () {
    expect(BleUuid.same('FE0F', HueGatt.advertisedService), isTrue);
    expect(BleUuid.same('fe0f', '0000FE0F-0000-1000-8000-00805F9B34FB'), isTrue);
    expect(BleUuid.same('180a', HueGatt.advertisedService), isFalse);
  });
}
