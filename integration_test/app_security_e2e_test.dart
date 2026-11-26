// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/sim/simulated_ble.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  const message = "This light uses Hue's extra security and needs the official app or a Hue Bridge.";

  e2e('adding a light that uses Hue extra security explains why it cannot be added', (tester, world) async {
    world.central.addBulb(SimulatedHueBulb(id: 'b1', name: 'New lamp', securityKey: SimulatedHueBulb.provisionedKey));
    await world.launch(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.pumpUntilFound(find.text('New lamp'));
    await tester.tapAndSettle(find.text('New lamp'));
    await tester.pumpUntilFound(find.text(message));
    expect(world.home.lights, isEmpty);
  });

  e2e('a light that refuses writes after bonding shows the extra security message', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));
    expect(find.byKey(const ValueKey('app-security-banner')), findsNothing);

    bulb.appSecurity = true;
    await tester.tapAndSettle(find.byKey(const ValueKey('power-switch')));
    await tester.pumpUntilFound(find.byKey(const ValueKey('app-security-banner')));
    expect(find.text(message), findsWidgets);
    expect(bulb.state.on, isFalse);
  });
}
