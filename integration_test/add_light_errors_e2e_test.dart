// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/transport/ble/ble_central.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  final banner = find.byKey(const ValueKey('error-banner'));

  Finder inBanner(Finder finder) => find.descendant(of: banner, matching: finder);

  e2e('with debug logging on, a Bluetooth error shows its raw detail', (tester, world) async {
    world.bulb('c4:2c:00:00:00:07', name: 'Porch');
    await world.launch(tester);
    await world.home.setDebugLogging(true);
    world.central.connectErrors.addAll([
      for (var i = 0; i < 5; i++) const BleOperationException(BleFailure.other, 'status 133 on connect', 'GATT_ERROR'),
    ]);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.pumpUntilFound(find.text('Porch'));
    await tester.tapAndSettle(find.text('Porch'));
    await tester.pumpUntilFound(banner);
    expect(inBanner(find.textContaining('Bluetooth error (GATT_ERROR)')), findsOneWidget);
    expect(inBanner(find.widgetWithText(SelectableText, 'status 133 on connect')), findsOneWidget);

    await world.home.setDebugLogging(false);
    await tester.settle(const Duration(milliseconds: 300));
    expect(inBanner(find.textContaining('Bluetooth error (GATT_ERROR)')), findsOneWidget);
    expect(inBanner(find.byType(SelectableText)), findsNothing, reason: 'the detail is for debugging only');
  });

  e2e('a scan that fails after a failed add says Bluetooth is off', (tester, world) async {
    world.bulb('c4:2c:00:00:00:08', name: 'Garden');
    await world.launch(tester);
    world.central.connectErrors.addAll([
      for (var i = 0; i < 5; i++) const BleOperationException(BleFailure.other, 'status 133 on connect', 'GATT_ERROR'),
    ]);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.pumpUntilFound(find.text('Garden'));
    await tester.tap(find.text('Garden'));
    // Bluetooth goes off while the add is under way, so the scan that
    // resumes after it fails.
    world.central.available = false;
    await tester.pumpUntilFound(inBanner(find.textContaining('Bluetooth is off')));
    expect(world.central.scans, 0, reason: 'no scan is running');
    expect(find.text('Garden'), findsOneWidget, reason: 'the found list is kept');
  });

  e2e('a bridge address entered from the keyboard pairs, and a failure shows a banner', (tester, world) async {
    await world.launch(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.tapAndSettle(find.text('Hue Bridge'));
    final host = find.byKey(const ValueKey('bridge-host'));
    await tester.pumpUntilFound(host);

    // An empty address does nothing.
    await tester.enterText(host, '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.settle(const Duration(milliseconds: 300));
    expect(find.text('Press the link button'), findsNothing);
    expect(world.home.bridges, isEmpty);

    world.bridge.pressLinkButton();
    world.bridge.failAll = true;
    await tester.enterText(host, ' 192.168.1.9 ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpUntilFound(inBanner(find.textContaining('HTTP 503')));
    expect(world.home.lights, isEmpty, reason: 'its lights could not be read');
    expect(host, findsOneWidget, reason: 'the address can be tried again');
  });
}
