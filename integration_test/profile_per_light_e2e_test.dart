import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  Finder profilesButtonOf(String name) =>
      find.descendant(of: tileOf(name), matching: find.byKey(const ValueKey('tile-profiles')));

  e2e('pick a profile for one light from its tile', (tester, world) async {
    final desk = world.bulb('b1', name: 'Desk lamp');
    final floor = world.bulb('b2', name: 'Floor lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await world.addBulbThroughUi(tester, 'Floor lamp');

    await tester.tapAndSettle(profilesButtonOf('Desk lamp'));
    await tester.pumpUntilFound(find.byKey(const ValueKey('profile-picker')));
    await tester.tapAndSettle(
      find.descendant(of: find.byKey(const ValueKey('profile-picker')), matching: find.text('Relax')),
    );
    await tester.pumpUntil(() => desk.state.color == const WhiteColor(447));
    expect(floor.state.color, isNot(const WhiteColor(447)));
  });

  e2e('pick a profile for one light on its screen', (tester, world) async {
    final desk = world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));
    final chip = find.byKey(const ValueKey('detail-profile-Concentrate'));
    await tester.pumpUntilFound(chip);
    await tester.tapAndSettle(chip);
    await tester.pumpUntil(() => desk.state.color == const WhiteColor(233));
  });

  e2e('a profile picked on a linked light reaches its lights and shows on it', (tester, world) async {
    final left = world.bulb('b1', name: 'Left strip');
    final right = world.bulb('b2', name: 'Right strip');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Left strip');
    await world.addBulbThroughUi(tester, 'Right strip');
    final room = await world.home.createRoom('TV backlight', ['ble:b1', 'ble:b2'], linked: true);
    await tester.settle(const Duration(milliseconds: 300));

    await tester.tapAndSettle(profilesButtonOf('TV backlight'));
    await tester.tapAndSettle(
      find.descendant(of: find.byKey(const ValueKey('profile-picker')), matching: find.text('Read')),
    );
    await tester.pumpUntil(
      () => left.state.color == const WhiteColor(346) && right.state.color == const WhiteColor(346),
    );
    expect(
      world.home.clusterLight(world.home.rooms.firstWhere((r) => r.id == room.id)).state.color,
      const WhiteColor(346),
    );

    // A favourite chip on Home updates the linked light as well.
    await tester.tapAndSettle(find.widgetWithText(ActionChip, 'Relax'));
    await tester.pumpUntil(
      () =>
          world.home.clusterLight(world.home.rooms.firstWhere((r) => r.id == room.id)).state.color ==
          const WhiteColor(447),
    );
  });
}
