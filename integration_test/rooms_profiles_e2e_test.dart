import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  Future<void> twoBulbs(WidgetTester tester, World world) async {
    world.bulb('b1', name: 'Desk lamp');
    world.bulb('b2', name: 'Floor lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await world.addBulbThroughUi(tester, 'Floor lamp');
  }

  e2e('create a room and switch it as one', (tester, world) async {
    await twoBulbs(tester, world);
    await tester.tapAndSettle(find.byKey(const ValueKey('home-menu')));
    await tester.tapAndSettle(find.text('New group'));
    await tester.enterText(find.byKey(const ValueKey('room-name')), 'Study');
    await tester.tapAndSettle(find.widgetWithText(CheckboxListTile, 'Desk lamp'));
    await tester.tapAndSettle(find.widgetWithText(CheckboxListTile, 'Floor lamp'));
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Save'));

    await tester.pumpUntilFound(find.byKey(const ValueKey('room-header-Study')));
    await tester.tapAndSettle(
      find.descendant(of: find.byKey(const ValueKey('room-header-Study')), matching: find.byType(Switch)),
    );
    await tester.pumpUntil(() => world.central.bulbs.values.every((b) => b.state.on == true));

    await tester.tapAndSettle(find.byKey(const ValueKey('all-off')));
    await tester.pumpUntil(() => world.central.bulbs.values.every((b) => b.state.on == false));
  });

  e2e('save a light as a profile and bring it back', (tester, world) async {
    await twoBulbs(tester, world);
    final desk = world.central.bulbs['b1']!;
    await tester.tapAndSettle(find.text('Desk lamp'));
    await tester.tapAndSettle(find.text('Colour'));
    final wheel = tester.getRect(find.byKey(const ValueKey('color-wheel')));
    await tester.tapAt(Offset(wheel.right - 4, wheel.center.dy));
    await tester.pumpUntil(() => desk.state.color is XyColor);
    final saved = desk.state.color;

    await tester.tapAndSettle(find.byKey(const ValueKey('light-menu')));
    await tester.tapAndSettle(find.text('Save as profile'));
    await tester.enterText(find.byType(TextField), 'Sunset');
    await tester.pump();
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Save'));
    await tester.pageBack();
    await tester.settle(const Duration(milliseconds: 600));

    await tester.tapAndSettle(find.text('Profiles'));
    await tester.pumpUntilFound(find.text('Sunset'));
    await tester.tapAndSettle(find.text('Sunset'));
    await tester.pumpUntilFound(find.text('Apply to'));
    await tester.tapAndSettle(find.widgetWithText(FilterChip, 'All lights'));
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpUntil(() => world.central.bulbs['b2']!.state.color == saved);
  });

  e2e('capture a scene from several lights', (tester, world) async {
    await twoBulbs(tester, world);
    await world.home.send('ble:b1', const LightCommand(on: true, brightness: 40, color: XyColor(0.6, 0.3)));
    await world.home.send('ble:b2', const LightCommand(on: true, brightness: 220, color: WhiteColor(250)));
    await tester.settle(const Duration(milliseconds: 300));

    await tester.tapAndSettle(find.text('Profiles'));
    await tester.tapAndSettle(find.byKey(const ValueKey('new-profile')));
    await tester.tapAndSettle(find.text('Scene from my lights'));
    await tester.enterText(find.byKey(const ValueKey('profile-name')), 'Movie night');
    await tester.tapAndSettle(find.widgetWithText(CheckboxListTile, 'Desk lamp'));
    await tester.tapAndSettle(find.widgetWithText(CheckboxListTile, 'Floor lamp'));
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpUntilFound(find.text('Movie night'));

    await world.home.allOff();
    await tester.tapAndSettle(find.text('Movie night'));
    await tester.pumpUntil(
      () => world.central.bulbs['b1']!.state.brightness == 40 && world.central.bulbs['b1']!.state.on == true,
    );
    expect(world.central.bulbs['b2']!.state.color, const WhiteColor(250));
  });

  e2e('a favourite profile on Home applies with one tap', (tester, world) async {
    await twoBulbs(tester, world);
    await tester.pumpUntilFound(find.widgetWithText(ActionChip, 'Relax'));
    await tester.tapAndSettle(find.widgetWithText(ActionChip, 'Relax'));
    await tester.pumpUntil(() => world.central.bulbs.values.every((b) => b.state.color == const WhiteColor(447)));
  });

  e2e('create a preset with the colour wheel', (tester, world) async {
    await twoBulbs(tester, world);
    await tester.tapAndSettle(find.text('Profiles'));
    await tester.tapAndSettle(find.byKey(const ValueKey('new-profile')));
    await tester.tapAndSettle(find.text('New colour preset'));
    await tester.enterText(find.byKey(const ValueKey('profile-name')), 'Ocean');
    final wheel = tester.getRect(find.byKey(const ValueKey('color-wheel')));
    // Hue 240 sits up and to the left of the centre.
    await tester.tapAt(wheel.center + Offset(-wheel.width * 0.22, -wheel.height * 0.38));
    await tester.pump();
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpUntil(() => world.home.profiles.any((p) => p.name == 'Ocean'));
    await tester.pumpUntilGone(find.byKey(const ValueKey('profile-name')));
    expect(find.text('Ocean'), findsOneWidget);
    final ocean = world.home.profiles.firstWhere((p) => p.name == 'Ocean');
    final xy = ocean.preset!.color as XyColor;
    expect(xy.y, lessThan(0.2), reason: 'blue');
  });

  e2e('delete a profile and undo', (tester, world) async {
    await twoBulbs(tester, world);
    await tester.tapAndSettle(find.text('Profiles'));
    await tester.pumpUntilFound(find.text('Energise'));
    await tester.tapAndSettle(find.byKey(const ValueKey('profile-menu-Energise')));
    await tester.tapAndSettle(find.text('Delete'));
    await tester.pumpUntilGone(find.text('Energise'));
    await tester.tapAndSettle(find.text('Undo'));
    await tester.pumpUntilFound(find.text('Energise'));
  });
}
