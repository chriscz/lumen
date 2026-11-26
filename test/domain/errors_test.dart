// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/errors.dart';

void main() {
  test('an error without raw detail has no details, and names its type', () {
    const error = BulbBusy();
    expect(error.details, isNull);
    expect(error.toString(), startsWith('BulbBusy: The bulb did not accept the connection.'));
  });

  test('errors with raw detail show it in diagnostics, but not when it is empty', () {
    expect(DiscoverableRefused('GATT 0x80').details, 'GATT 0x80');
    expect(DiscoverableRefused('').details, isNull);
    expect(CharacteristicMissing('932c32bd-0005 not found').details, '932c32bd-0005 not found');
    expect(CharacteristicMissing().details, isNull);
    expect(BluetoothError('133', 'GATT_ERROR').details, 'GATT_ERROR');
    expect(BluetoothError('133', '').details, isNull);
  });

  test('the bluetooth error message names the code for the user', () {
    expect(BluetoothError('133', '').message, startsWith('Bluetooth error (133). Try again.'));
  });

  test('the bridge errors tell the user what to do', () {
    // Built at run time, so the constructors themselves run and are checked.
    // ignore: prefer_const_constructors
    expect(LinkButtonNotPressed().message, contains('link button'));
    // ignore: prefer_const_constructors
    expect(BridgeUnauthorized().message, contains('Pair it again'));
    expect(const BridgeUnreachable().message, contains('same network'));
    // ignore: prefer_const_constructors
    expect(BridgeOffline(), isA<BridgeUnreachable>());
    expect(const BridgeOffline().message, contains('same network'));
  });

  test('a permanently denied permission points to the app settings', () {
    expect(const BluetoothPermissionDenied(permanent: true).message, contains('app settings'));
    expect(const BluetoothPermissionDenied().message, isNot(contains('app settings')));
  });

  test('the pairing advice mentions the bridge only when the bulb is on one', () {
    expect(const NotInPairingMode(onBridge: true).message, contains('Hue Bridge'));
    expect(const NotInPairingMode().message, isNot(contains('Hue Bridge')));
  });
}
