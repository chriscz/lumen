// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  e2e('an on/off light shows a switch and no brightness', (tester, world) async {
    world.bulb('p1', name: 'Plug', model: 'LOM001');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Plug');
    expect(find.descendant(of: tileOf('Plug'), matching: find.byKey(const ValueKey('tile-brightness'))), findsNothing);

    await tester.tapAndSettle(powerSwitchOf('Plug'));
    await tester.pumpUntilFound(find.descendant(of: tileOf('Plug'), matching: find.text('On')));

    await tester.tapAndSettle(find.text('Plug'));
    await tester.pumpUntilFound(find.byKey(const ValueKey('power-switch')));
    expect(find.byKey(const ValueKey('brightness-slider')), findsNothing);
    expect(find.byKey(const ValueKey('temperature-slider')), findsNothing);
    expect(find.text('Effects'), findsNothing);
  });

  e2e('only the effects the light supports are offered', (tester, world) async {
    // Light type colour, effect bitmask with candle (bit 1) and sunbeam (bit 16).
    final bulb = world.central.addBulb(
      SimulatedHueBulb(id: 'b1', name: 'Desk lamp', capabilities: [0x00, 0x01, 0x03, 0x04, 0x03, 0x02, 0x00, 0x01]),
    );
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));

    final sunbeam = find.widgetWithText(ChoiceChip, 'Sunbeam');
    await tester.scrollUntilVisible(sunbeam, 200, scrollable: find.byType(Scrollable).first);
    expect(find.byType(ChoiceChip), findsNWidgets(3));
    expect(find.widgetWithText(ChoiceChip, 'Candle'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Prism'), findsNothing);
    await tester.tapAndSettle(sunbeam);
    await tester.pumpUntil(() => bulb.state.effect == HueEffect.sunbeam);
  });

  e2e('the temperature slider spans the range the light reports', (tester, world) async {
    final bulb = world.bulb('t1', name: 'Ambiance', model: 'LTA001');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Ambiance');
    await tester.tapAndSettle(find.text('Ambiance'));

    final temperature = find.byKey(const ValueKey('temperature-slider'));
    await tester.pumpUntilFound(temperature);
    final slider = tester.widget<Slider>(temperature);
    expect((slider.min, slider.max), (153, 454));
    final t = tester.getRect(temperature);
    await tester.tapAt(Offset(t.left + 2, t.center.dy));
    await tester.pumpUntil(() => bulb.state.color == const WhiteColor(454));
  });
}
