// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/sim/simulated_ble.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  e2e('a bulb bonded with this phone is listed although it does not advertise, and can be added', (
    tester,
    world,
  ) async {
    final bulb = world.central.addBulb(
      SimulatedHueBulb(id: 'c4:2c:00:00:00:09', name: 'Hall lamp', bondedElsewhere: true),
    );
    await world.launch(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.pumpUntilFound(find.text('Paired with this phone'));
    await tester.tapAndSettle(find.text('Hall lamp'));
    await tester.pumpUntilFound(tileOf('Hall lamp'));
    expect(world.central.pairCalls, 0, reason: 'a bonded bulb needs no pairing mode');

    await tester.tapAndSettle(powerSwitchOf('Hall lamp'));
    await tester.pumpUntil(() => bulb.state.on == true);
  });

  e2e('the pairing help card gives the steps that work', (tester, world) async {
    await world.launch(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    final help = find.byKey(const ValueKey('pairing-help'));
    await tester.pumpUntilFound(help);
    await tester.tapAndSettle(help);
    expect(find.textContaining('Close the Hue app'), findsOneWidget);
    expect(find.textContaining('Make discoverable'), findsOneWidget);
    expect(find.textContaining('five times'), findsOneWidget);
    expect(find.textContaining('switch the bulb off and on and add it'), findsNothing);
  });

  e2e('Retry adds the bulb once it is discoverable, and Copy diagnostics copies the log', (tester, world) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final bulb = world.bulb('c4:2c:00:00:00:02', name: 'Shy bulb', pairingMode: false);
    await world.launch(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.pumpUntilFound(find.text('Shy bulb'));
    await tester.tapAndSettle(find.text('Shy bulb'));
    await tester.pumpUntilFound(find.textContaining('not discoverable'));

    await tester.tapAndSettle(find.byKey(const ValueKey('copy-diagnostics')));
    expect(copied.single, contains('c4:2c:00:00:00:02'));

    bulb.pairingMode = true;
    await tester.tapAndSettle(find.byKey(const ValueKey('retry-add')));
    await tester.pumpUntilFound(tileOf('Shy bulb'));
  });

  e2e('the scan list marks bulbs that are ready to pair', (tester, world) async {
    world.bulb('c4:2c:00:00:00:01', name: 'Open bulb');
    world.bulb('c4:2c:00:00:00:02', name: 'Closed bulb', pairingMode: false);
    await world.launch(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.pumpUntilFound(find.text('Closed bulb'));
    await tester.pumpUntilFound(find.text('Open bulb'));
    expect(find.byKey(const ValueKey('ready-to-pair-c4:2c:00:00:00:01')), findsOneWidget);
    expect(find.byKey(const ValueKey('ready-to-pair-c4:2c:00:00:00:02')), findsNothing);
    expect(find.text('Ready to pair'), findsOneWidget);
  });

  e2e('a bulb past its power-on window asks to be switched off and on', (tester, world) async {
    world.central.addBulb(
      SimulatedHueBulb(id: 'c4:2c:00:00:00:03', name: 'Late bulb', pairingMode: false, windowExpired: true),
    );
    await world.launch(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.pumpUntilFound(find.text('Late bulb'));
    await tester.tapAndSettle(find.text('Late bulb'));
    await tester.pumpUntilFound(find.textContaining('Switch the bulb off and on, then add it within a minute'));
  });

  e2e('make discoverable opens a bulb for another app and repeats while the sheet is open', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));
    await tester.tapAndSettle(find.byKey(const ValueKey('light-menu')));
    await tester.tapAndSettle(find.text('Make discoverable'));
    await tester.pumpUntil(() => bulb.makeDiscoverableWrites == 1);
    expect(find.textContaining('about 5 minutes'), findsOneWidget);

    await tester.pump(const Duration(minutes: 4, seconds: 1));
    await tester.pumpUntil(() => bulb.makeDiscoverableWrites == 2);

    await tester.tapAndSettle(find.byKey(const ValueKey('discoverable-done')));
    await tester.pump(const Duration(minutes: 9));
    expect(bulb.makeDiscoverableWrites, 2);
  });

  e2e('a light that refuses make discoverable says so', (tester, world) async {
    world.central.addBulb(SimulatedHueBulb(id: 'b1', name: 'Desk lamp', refusesDiscoverable: true));
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));
    await tester.tapAndSettle(find.byKey(const ValueKey('light-menu')));
    await tester.tapAndSettle(find.text('Make discoverable'));
    await tester.pumpUntilFound(find.textContaining('refused to become discoverable'));
  });
}
