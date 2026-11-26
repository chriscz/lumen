// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/domain/power_on.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  Future<void> openPowerOn(WidgetTester tester) async {
    await tester.tapAndSettle(find.byKey(const ValueKey('light-menu')));
    await tester.tapAndSettle(find.text('When power returns'));
    await tester.pumpUntilFound(find.byKey(const ValueKey('power-on-alwaysOff')));
  }

  PowerOnMode? selected(WidgetTester tester) =>
      tester.widget<RadioGroup<PowerOnMode>>(find.byType(RadioGroup<PowerOnMode>)).groupValue;

  e2e('choose what a light does when its power returns', (tester, world) async {
    final bulb = world.central.addBulb(
      SimulatedHueBulb(
        id: 'b1',
        name: 'Desk lamp',
        state: const LightState(on: true, brightness: 200, color: WhiteColor(300)),
      ),
    );
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));

    await openPowerOn(tester);
    expect(selected(tester), PowerOnMode.alwaysOn, reason: 'the bulb starts at a fixed warm white');

    await tester.tapAndSettle(find.text('Always off'));
    await tester.pumpUntil(() => bulb.startup![2] == 0x00);
    expect(bulb.startup, [
      0x01,
      0x01,
      0x00,
      0x02,
      0x01,
      0xFF,
      0x03,
      0x02,
      0xFF,
      0xFF,
      0x04,
      0x04,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
    ]);
    expect(selected(tester), PowerOnMode.alwaysOff);

    await tester.tapAndSettle(find.text('Last state'));
    await tester.pumpUntil(() => bulb.startup![2] == 0xFF);
    expect(bulb.startup, [
      0x01,
      0x01,
      0xFF,
      0x02,
      0x01,
      0xFF,
      0x03,
      0x02,
      0xFF,
      0xFF,
      0x04,
      0x04,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
    ]);

    await tester.tapAndSettle(find.text('Always on'));
    await tester.pumpUntil(() => bulb.startup![2] == 0x01);
    expect(bulb.startup, [0x01, 0x01, 0x01, 0x02, 0x01, 200, 0x03, 0x02, 0x2C, 0x01]);
  });

  e2e('a light without the startup characteristic has no power-on menu', (tester, world) async {
    world.central.addBulb(SimulatedHueBulb(id: 'b1', name: 'Desk lamp', hasStartup: false));
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));
    await tester.tapAndSettle(find.byKey(const ValueKey('light-menu')));
    expect(find.text('Identify'), findsOneWidget);
    expect(find.text('When power returns'), findsNothing);
  });

  e2e('set the minimum brightness of a light', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));
    await tester.tapAndSettle(find.byKey(const ValueKey('light-menu')));
    await tester.tapAndSettle(find.text('Minimum brightness'));
    final slider = find.byKey(const ValueKey('min-dim-slider'));
    await tester.pumpUntilFound(slider);
    final r = tester.getRect(slider);
    await tester.tapAt(Offset(r.left + r.width / 2, r.center.dy));
    await tester.pump();
    await tester.tapAndSettle(find.byKey(const ValueKey('min-dim-save')));
    await tester.pumpUntil(() => bulb.minDim![0] != 1);
    expect(bulb.writes.last.characteristic, HueGatt.minDim);
    expect(bulb.minDim!.single, inInclusiveRange(118, 138));
  });

  e2e('a write-only minimum brightness opens without a value and then shows the one saved', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));
    await tester.tapAndSettle(find.byKey(const ValueKey('light-menu')));
    await tester.tapAndSettle(find.text('Minimum brightness'));
    final slider = find.byKey(const ValueKey('min-dim-slider'));
    await tester.pumpUntilFound(slider);
    expect(find.byKey(const ValueKey('min-dim-unknown')), findsOneWidget);
    final r = tester.getRect(slider);
    await tester.tapAt(Offset(r.left + r.width / 4, r.center.dy));
    await tester.pump();
    await tester.tapAndSettle(find.byKey(const ValueKey('min-dim-save')));
    await tester.pumpUntil(() => bulb.minDim![0] != 1);

    await tester.tapAndSettle(find.byKey(const ValueKey('light-menu')));
    await tester.tapAndSettle(find.text('Minimum brightness'));
    await tester.pumpUntilFound(slider);
    expect(find.byKey(const ValueKey('min-dim-unknown')), findsNothing);
    expect(tester.widget<Slider>(slider).value, closeTo(HueBleCodec.brightnessLevel(bulb.minDim!.single), 0.01));
  });

  e2e('a light without the characteristic has no minimum brightness', (tester, world) async {
    world.central.addBulb(SimulatedHueBulb(id: 'b1', name: 'Desk lamp', hasMinDim: false));
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));
    await tester.tapAndSettle(find.byKey(const ValueKey('light-menu')));
    expect(find.text('When power returns'), findsOneWidget);
    expect(find.text('Minimum brightness'), findsNothing);
  });
}
