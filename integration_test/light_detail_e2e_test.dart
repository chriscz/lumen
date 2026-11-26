// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/domain/power_on.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/transport/ble/ble_central.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';
import 'package:lumen/ui/light_detail_screen.dart';
import 'package:lumen/ui/widgets/prompts.dart';
import 'package:lumen/ui/widgets/light_controls.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  /// Adds the bulb through the UI and opens its screen.
  Future<SimulatedHueBulb> openDetail(WidgetTester tester, World world, {SimulatedHueBulb? bulb}) async {
    final added = bulb == null ? world.bulb('b1', name: 'Desk lamp') : world.central.addBulb(bulb);
    await world.launch(tester);
    await world.addBulbThroughUi(tester, added.name);
    await tester.tapAndSettle(find.text(added.name));
    await tester.pumpUntilFound(find.byType(LightDetailScreen));
    return added;
  }

  Finder detailScrollable() =>
      find.descendant(of: find.byType(LightDetailScreen), matching: find.byType(Scrollable)).first;

  /// Scrolls the detail screen to its end without a drag, which the colour
  /// wheel would claim.
  Future<void> scrollToEnd(WidgetTester tester) async {
    final position = tester.state<ScrollableState>(detailScrollable()).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.settle(const Duration(milliseconds: 300));
  }

  Future<void> openMenuItem(WidgetTester tester, String item) async {
    await tester.tapAndSettle(find.byKey(const ValueKey('light-menu')));
    await tester.tapAndSettle(find.text(item));
  }

  BleOperationException gattError(String characteristic) =>
      BleOperationException(BleFailure.other, 'write failed on $characteristic', 'GATT_ERROR');

  e2e('the star marks a light as a favourite, also on its Home tile', (tester, world) async {
    await openDetail(tester, world);
    await tester.tapAndSettle(find.byTooltip('Add to favourites'));
    expect(world.home.light('ble:b1')!.favorite, isTrue);
    expect(find.byTooltip('Remove from favourites'), findsOneWidget);

    await tester.pageBack();
    await tester.settle(const Duration(milliseconds: 600));
    expect(find.descendant(of: tileOf('Desk lamp'), matching: find.byIcon(Icons.star_rounded)), findsOneWidget);

    await tester.tapAndSettle(find.text('Desk lamp'));
    await tester.tapAndSettle(find.byTooltip('Remove from favourites'));
    expect(world.home.light('ble:b1')!.favorite, isFalse);
  });

  e2e('a swatch sends its colour and switches between the white and colour controls', (tester, world) async {
    final bulb = await openDetail(tester, world);
    final swatches = find.descendant(of: find.byType(Swatches), matching: find.byType(InkResponse));

    await scrollToEnd(tester);
    await tester.tapAndSettle(swatches.at(0));
    await tester.pumpUntil(() => bulb.state.color == const WhiteColor(454));
    expect(find.byType(TemperatureSlider), findsOneWidget);
    expect(find.byKey(const ValueKey('color-wheel')), findsNothing);

    await scrollToEnd(tester);
    await tester.tapAndSettle(swatches.at(4));
    await tester.pumpUntil(() => bulb.state.color is XyColor);
    expect((bulb.state.color! as XyColor).x, greaterThan(0.6), reason: 'the red swatch');
    expect(find.byKey(const ValueKey('color-wheel')), findsOneWidget);
    expect(find.byType(TemperatureSlider), findsNothing);
  });

  e2e('a screen reader turns the colour wheel and the light follows', (tester, world) async {
    final semantics = tester.ensureSemantics();
    final bulb = await openDetail(tester, world);
    await tester.tapAndSettle(find.text('Colour'));
    final rect = tester.getRect(find.byKey(const ValueKey('color-wheel')));
    await tester.tapAt(Offset(rect.right - 4, rect.center.dy));
    await tester.pumpUntil(() => bulb.state.color is XyColor);
    await tester.settle(const Duration(milliseconds: 300));
    final wheel = find.semantics.byLabel('Colour wheel');
    expect(wheel.evaluate().single.value, startsWith('hue 0 degrees'));
    final red = bulb.state.color! as XyColor;

    tester.semantics.increase(wheel);
    await tester.pumpUntil(() => bulb.state.color != red);
    await tester.settle(const Duration(milliseconds: 300));
    expect(wheel.evaluate().single.value, startsWith('hue 15 degrees'));
    final orange = bulb.state.color! as XyColor;
    expect(orange.y, greaterThan(red.y), reason: 'turning up moves from red towards yellow');

    tester.semantics.decrease(wheel);
    tester.semantics.decrease(wheel);
    await tester.pumpUntil(() => bulb.state.color != orange);
    await tester.settle(const Duration(milliseconds: 300));
    expect(wheel.evaluate().single.value, startsWith('hue 345 degrees'));
    expect((bulb.state.color! as XyColor).y, lessThan(red.y), reason: 'turning down moves towards pink');
    semantics.dispose();
  });

  e2e('the effect speed slider changes the speed of the running effect', (tester, world) async {
    final bulb = await openDetail(tester, world);
    final candle = find.widgetWithText(ChoiceChip, 'Candle');
    await tester.scrollUntilVisible(candle, 200, scrollable: detailScrollable());
    await tester.tapAndSettle(candle);
    await tester.pumpUntil(() => bulb.state.effect == HueEffect.candle);

    final speed = find.byKey(const ValueKey('effect-speed'));
    await scrollToEnd(tester);
    await tester.pumpUntilFound(speed);
    final r = tester.getRect(speed);
    await tester.tapAt(Offset(r.left + r.width * 0.9, r.center.dy));
    await tester.pumpUntil(() => (bulb.state.effectSpeed ?? 128) > 200);
    expect(bulb.state.effect, HueEffect.candle, reason: 'the effect keeps running');
  });

  e2e('rename from the keyboard; an empty name cannot be saved, and Cancel keeps the name', (tester, world) async {
    final bulb = await openDetail(tester, world);
    await openMenuItem(tester, 'Rename');
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed, isNull);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.settle(const Duration(milliseconds: 300));
    expect(find.byType(RenameDialog), findsOneWidget, reason: 'an empty name is not submitted');

    await tester.tapAndSettle(find.widgetWithText(TextButton, 'Cancel'));
    expect(find.byType(RenameDialog), findsNothing);
    expect(world.home.light('ble:b1')!.name, 'Desk lamp');

    await openMenuItem(tester, 'Rename');
    await tester.enterText(find.byType(TextField), '  Reading lamp ');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpUntil(() => bulb.name == 'Reading lamp');
    await tester.pumpUntilFound(find.text('Reading lamp'));
    expect(world.home.light('ble:b1')!.name, 'Reading lamp');
  });

  e2e('minimum brightness shows a failed read and a failed save, then saves on retry', (tester, world) async {
    final bulb = await openDetail(tester, world);
    bulb.inRange = false;
    world.central.dropConnection('b1');
    await openMenuItem(tester, 'Minimum brightness');
    await tester.pumpUntilFound(find.textContaining('out of reach'));
    expect(find.byKey(const ValueKey('min-dim-slider')), findsNothing);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('min-dim-save'))).onPressed, isNull);
    await tester.tapAt(const Offset(200, 100));
    await tester.settle(const Duration(milliseconds: 600));

    bulb.inRange = true;
    bulb.refuseWrite = (c, _) => c == HueGatt.minDim ? gattError(c) : null;
    await openMenuItem(tester, 'Minimum brightness');
    final slider = find.byKey(const ValueKey('min-dim-slider'));
    await tester.pumpUntilFound(slider);
    final r = tester.getRect(slider);
    await tester.tapAt(Offset(r.left + r.width / 2, r.center.dy));
    await tester.pump();
    await tester.tapAndSettle(find.byKey(const ValueKey('min-dim-save')));
    await tester.pumpUntilFound(find.textContaining('Bluetooth error (GATT_ERROR)'));
    expect(slider, findsOneWidget, reason: 'the sheet stays open');
    expect(bulb.minDim, [1], reason: 'nothing was written');

    bulb.refuseWrite = null;
    await tester.tapAndSettle(find.byKey(const ValueKey('min-dim-save')));
    await tester.pumpUntilGone(slider);
    expect(bulb.minDim!.single, inInclusiveRange(118, 138));
  });

  e2e('when power returns shows a failed read and a failed save', (tester, world) async {
    final bulb = await openDetail(tester, world);
    bulb.inRange = false;
    world.central.dropConnection('b1');
    await openMenuItem(tester, 'When power returns');
    await tester.pumpUntilFound(find.textContaining('out of reach'));
    expect(
      tester.widget<RadioGroup<PowerOnMode>>(find.byType(RadioGroup<PowerOnMode>)).groupValue,
      isNull,
      reason: 'nothing is known',
    );
    await tester.tapAt(const Offset(200, 100));
    await tester.settle(const Duration(milliseconds: 600));

    bulb.inRange = true;
    bulb.refuseWrite = (c, _) => c == HueGatt.startup ? gattError(c) : null;
    await openMenuItem(tester, 'When power returns');
    await tester.pumpUntilFound(find.byKey(const ValueKey('power-on-alwaysOff')));
    expect(find.textContaining('out of reach'), findsNothing);
    await tester.tapAndSettle(find.text('Always off'));
    await tester.pumpUntilFound(find.textContaining('Bluetooth error (GATT_ERROR)'));
    expect(
      tester.widget<RadioGroup<PowerOnMode>>(find.byType(RadioGroup<PowerOnMode>)).groupValue,
      PowerOnMode.alwaysOn,
      reason: 'the choice stays as the light has it',
    );
    expect(bulb.startup, SimulatedHueBulb.defaultStartup);
  });

  e2e('a power-on behaviour set by another app is explained and can be replaced', (tester, world) async {
    final bulb = await openDetail(tester, world);
    // Power as it was, at a fixed brightness: none of the three choices.
    bulb.startup = [0x01, 0x01, 0xFF, 0x02, 0x01, 0x80];
    await openMenuItem(tester, 'When power returns');
    await tester.pumpUntilFound(find.textContaining('Another app set a custom behaviour'));
    expect(tester.widget<RadioGroup<PowerOnMode>>(find.byType(RadioGroup<PowerOnMode>)).groupValue, PowerOnMode.custom);
    await tester.tapAndSettle(find.text('Last state'));
    await tester.pumpUntil(() => bulb.startup![2] == 0xFF && bulb.startup!.length > 6);
    await tester.pumpUntilGone(find.textContaining('Another app set a custom behaviour'));
  });
}
