import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  Future<void> threeBulbs(WidgetTester tester, World world) async {
    world.bulb('b1', name: 'Desk lamp');
    world.bulb('b2', name: 'Floor lamp');
    world.bulb('b3', name: 'Shelf', model: 'LTA001');
    await world.launch(tester);
    for (final n in ['Desk lamp', 'Floor lamp', 'Shelf']) {
      await world.addBulbThroughUi(tester, n);
    }
  }

  e2e('select lights with a long press and group them', (tester, world) async {
    await threeBulbs(tester, world);
    await tester.longPress(tileOf('Desk lamp'));
    await tester.settle(const Duration(milliseconds: 300));
    await tester.tapAndSettle(tileOf('Floor lamp'));
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tapAndSettle(find.byKey(const ValueKey('group-selected')));
    await tester.enterText(find.byType(TextField), 'Study');
    await tester.pump();
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpUntilFound(find.byKey(const ValueKey('room-header-Study')));
    final study = world.home.rooms.single;
    expect(world.home.lightsIn(study.id).map((l) => l.name), unorderedEquals(['Desk lamp', 'Floor lamp']));
    expect(find.text('2 selected'), findsNothing);
  });

  e2e('a group screen sets colour, white and brightness on every light in it', (tester, world) async {
    await threeBulbs(tester, world);
    await world.home.createRoom('Lounge', ['ble:b1', 'ble:b2', 'ble:b3']);
    await tester.settle(const Duration(milliseconds: 300));

    await tester.tapAndSettle(find.byKey(const ValueKey('room-header-Lounge')));
    await tester.pumpUntilFound(find.byKey(const ValueKey('group-detail')));
    await tester.tapAndSettle(find.byKey(const ValueKey('power-switch')));
    await tester.pumpUntil(() => world.central.bulbs.values.every((b) => b.state.on == true));

    await tester.tapAndSettle(find.text('Colour'));
    final wheel = tester.getRect(find.byKey(const ValueKey('color-wheel')));
    await tester.tapAt(Offset(wheel.right - 6, wheel.center.dy));
    await tester.pumpUntil(
      () =>
          [world.central.bulbs['b1']!, world.central.bulbs['b2']!].every((b) => (b.state.color as XyColor?)?.x != null),
    );
    // The white ambiance bulb shows the closest white instead.
    expect(world.central.bulbs['b3']!.state.color, isA<WhiteColor>());

    final brightness = find.byKey(const ValueKey('brightness-slider'));
    await tester.ensureVisible(brightness);
    await tester.settle(const Duration(milliseconds: 200));
    final b = tester.getRect(brightness);
    await tester.tapAt(Offset(b.left + b.width * 0.25, b.center.dy));
    await tester.pumpUntil(() {
      final levels = world.central.bulbs.values.map((x) => x.state.brightness!).toSet();
      return levels.length == 1 && levels.single < 110;
    });
  });
}
