import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/color/color_math.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';
import 'package:lumen/ui/widgets/color_wheel.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  e2e('pick a colour on the wheel in one combined write', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');

    await tester.tapAndSettle(find.text('Desk lamp'));
    await tester.tapAndSettle(find.text('Colour'));
    await tester.pumpUntilFound(find.byKey(const ValueKey('color-wheel')));
    final writes = bulb.writes.length;
    final wheel = tester.getRect(find.byKey(const ValueKey('color-wheel')));
    // The right edge of the wheel is hue 0: red.
    await tester.tapAt(Offset(wheel.right - 4, wheel.center.dy));
    await tester.pumpUntil(() => bulb.state.color is XyColor && (bulb.state.color as XyColor).x > 0.6);
    expect(bulb.state.on, isTrue);

    final first = bulb.writes[writes];
    expect(first.characteristic, HueGatt.control);
    final decoded = HueBleCodec.decodeControl(first.value);
    expect(decoded.on, isTrue, reason: 'power and colour travel in one write');
    expect(decoded.color, isA<XyColor>());
  });

  e2e('the colour wheel follows a colour set from elsewhere', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');

    await tester.tapAndSettle(find.text('Desk lamp'));
    await tester.tapAndSettle(find.text('Colour'));
    final wheel = find.byKey(const ValueKey('color-wheel'));
    await tester.pumpUntilFound(wheel);
    final rect = tester.getRect(wheel);
    // Just above the right edge: a red a little short of hue 360.
    await tester.tapAt(Offset(rect.right - 8, rect.center.dy - 8));
    await tester.pumpUntil(() => bulb.state.color is XyColor && (bulb.state.color as XyColor).x > 0.6);
    await tester.settle(const Duration(milliseconds: 300));
    final tapped = tester.widget<ColorWheel>(wheel);
    expect(tapped.hue, greaterThan(350), reason: 'the thumb stays where it was tapped');

    const blue = XyColor(0.1532, 0.0475);
    await world.home.setColor('ble:b1', blue);
    await tester.settle(const Duration(milliseconds: 300));
    final (hue, _) = ColorMath.xyToHueSat(blue);
    expect(tester.widget<ColorWheel>(wheel).hue, closeTo(hue, 1));
  });

  e2e('white temperature and brightness sliders', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));

    await tester.tapAndSettle(find.text('White'));
    final temperature = find.byKey(const ValueKey('temperature-slider'));
    await tester.pumpUntilFound(temperature);
    final t = tester.getRect(temperature);
    await tester.tapAt(Offset(t.left + 2, t.center.dy));
    await tester.pumpUntil(() => bulb.state.color == const WhiteColor(500));

    final brightness = find.byKey(const ValueKey('brightness-slider'));
    final b = tester.getRect(brightness);
    await tester.tapAt(Offset(b.left + b.width * 0.5, b.center.dy));
    await tester.pumpUntil(() => (bulb.state.brightness! - 127).abs() <= 8);
    expect(find.textContaining('%'), findsWidgets);
  });

  e2e('controls match what each bulb can do', (tester, world) async {
    world.bulb('w1', name: 'Plain', model: 'LWA001');
    world.bulb('t1', name: 'Ambiance', model: 'LTA001');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Plain');
    await world.addBulbThroughUi(tester, 'Ambiance');

    await tester.tapAndSettle(find.text('Plain'));
    await tester.pumpUntilFound(find.byKey(const ValueKey('brightness-slider')));
    expect(find.byKey(const ValueKey('color-wheel')), findsNothing);
    expect(find.byKey(const ValueKey('temperature-slider')), findsNothing);
    await tester.pageBack();
    await tester.settle(const Duration(milliseconds: 600));

    await tester.tapAndSettle(find.text('Ambiance'));
    await tester.pumpUntilFound(find.byKey(const ValueKey('temperature-slider')));
    expect(find.byKey(const ValueKey('color-wheel')), findsNothing);
  });

  e2e('rename a light on the bulb too, and the name survives a restart', (tester, world) async {
    world.bulb('b1', name: 'Hue color lamp 3');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Hue color lamp 3');
    await tester.tapAndSettle(find.text('Hue color lamp 3'));

    await tester.tapAndSettle(find.byKey(const ValueKey('light-menu')));
    await tester.tapAndSettle(find.text('Rename'));
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    final save = find.widgetWithText(FilledButton, 'Save');
    expect(tester.widget<FilledButton>(save).onPressed, isNull, reason: 'empty name');
    await tester.enterText(find.byType(TextField), 'Reading lamp');
    await tester.pump();
    await tester.tapAndSettle(save);
    await tester.pumpUntil(() => world.central.bulbs['b1']!.name == 'Reading lamp');
    await tester.pageBack();
    await tester.pumpUntilFound(tileOf('Reading lamp'));

    await world.launch(tester);
    await tester.pumpUntilFound(tileOf('Reading lamp'));
  });

  e2e('remove a light and undo', (tester, world) async {
    world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));

    await tester.tapAndSettle(find.byKey(const ValueKey('light-menu')));
    await tester.tapAndSettle(find.text('Remove'));
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpUntilFound(find.text('No lights yet'));
    await tester.tapAndSettle(find.text('Undo'));
    await tester.pumpUntilFound(tileOf('Desk lamp'));
  });

  e2e('a bulb out of range at launch shows as unreachable', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Garden');
    world.bulb('b2', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Garden');
    await world.addBulbThroughUi(tester, 'Desk lamp');

    bulb.inRange = false;
    world.central.dropConnection('b1');
    world.central.dropConnection('b2');
    await world.launch(tester);
    await tester.pumpUntilFound(find.descendant(of: tileOf('Garden'), matching: find.text('Unreachable')));
    expect(find.descendant(of: tileOf('Desk lamp'), matching: find.text('Unreachable')), findsNothing);
  });

  e2e('identify sends the blink command to 0006', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));
    final writes = bulb.writes.length;
    await tester.tapAndSettle(find.byKey(const ValueKey('light-menu')));
    await tester.tapAndSettle(find.text('Identify'));
    await tester.pumpUntil(() => bulb.identifies == 1);
    expect(bulb.writes.skip(writes).single.characteristic, HueGatt.identify);
    expect(bulb.writes.last.value, [0x01]);
  });

  e2e('identify blinks the power of a bulb without the blink command', (tester, world) async {
    final bulb = world.central.addBulb(SimulatedHueBulb(id: 'b1', name: 'Desk lamp', identifySupported: false));
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));
    final writes = bulb.writes.length;
    await tester.tapAndSettle(find.byKey(const ValueKey('light-menu')));
    await tester.tapAndSettle(find.text('Identify'));
    await tester.pumpUntil(() => bulb.writes.length - writes == 4);
    expect(bulb.writes.skip(writes).map((w) => w.characteristic), List.filled(4, HueGatt.control));
  });
  e2e('drag a finger around the colour wheel and the light follows', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    // A smaller phone, so the detail screen scrolls and competes for drags.
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3;
    await tester.pump();
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));
    await tester.tapAndSettle(find.text('Colour'));
    final wheelFinder = find.byKey(const ValueKey('color-wheel'));
    await tester.pumpUntilFound(wheelFinder);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;
    final wheel = tester.getRect(wheelFinder);
    final writes = bulb.writes.length;

    // From the red rim straight up, then left to the blue-violet top: the
    // vertical part is what a scrolling list would otherwise take.
    final start = Offset(wheel.center.dx + wheel.width * 0.35, wheel.center.dy);
    final gesture = await tester.startGesture(start);
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(start + Offset(0, -wheel.height * 0.035 * i));
      await tester.pump(const Duration(milliseconds: 30));
    }
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(start + Offset(-wheel.width * 0.035 * i, -wheel.height * 0.35));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    await tester.settle(const Duration(milliseconds: 500));

    expect(tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels, scroll);
    expect(bulb.writes.length - writes, greaterThan(1));
    final xy = bulb.state.color as XyColor;
    expect(xy.y, lessThan(0.25), reason: 'ended near blue-violet, got $xy');
  });
}
