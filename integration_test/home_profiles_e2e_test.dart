// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/log/logger.dart';
import 'package:lumen/ui/add_light_screen.dart';
import 'package:lumen/ui/light_detail_screen.dart';
import 'package:lumen/ui/widgets/prompts.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  Future<void> twoBulbs(WidgetTester tester, World world) async {
    world.bulb('b1', name: 'Desk lamp');
    world.bulb('b2', name: 'Shelf', model: 'LTA001');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await world.addBulbThroughUi(tester, 'Shelf');
  }

  Finder chip(String label) => find.widgetWithText(FilterChip, label);

  bool chipSelected(WidgetTester tester, String label) => tester.widget<FilterChip>(chip(label)).selected;

  e2e('picking lights ends with Cancel or the back gesture, which stays on Home', (tester, world) async {
    await twoBulbs(tester, world);
    await tester.longPress(tileOf('Desk lamp'));
    await tester.settle(const Duration(milliseconds: 300));
    expect(find.text('1 selected'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(const ValueKey('link-selected'))).onPressed,
      isNull,
      reason: 'a cluster takes two lights or more',
    );

    await tester.tapAndSettle(find.byTooltip('Cancel'));
    expect(find.text('1 selected'), findsNothing);
    expect(find.text('Home'), findsWidgets);

    await tester.longPress(tileOf('Shelf'));
    await tester.settle(const Duration(milliseconds: 300));
    expect(find.text('1 selected'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.settle(const Duration(milliseconds: 300));
    expect(find.text('1 selected'), findsNothing);
    expect(tileOf('Shelf'), findsOneWidget, reason: 'back leaves picking, not the app');

    // A plain tap opens the light again.
    await tester.tapAndSettle(find.text('Shelf'));
    await tester.pumpUntilFound(find.byType(LightDetailScreen));
  });

  e2e('Add light from the Home menu opens the add screen', (tester, world) async {
    await world.launch(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('home-menu')));
    await tester.tapAndSettle(
      find.descendant(of: find.byType(PopupMenuItem<String>), matching: find.text('Add light')),
    );
    await tester.pumpUntilFound(find.byType(AddLightScreen));
  });

  e2e('the brightness slider on a Home tile dims the bulb', (tester, world) async {
    await twoBulbs(tester, world);
    final desk = world.central.bulbs['b1']!;
    await tester.tapAndSettle(powerSwitchOf('Desk lamp'));
    await tester.pumpUntil(() => desk.state.on == true);
    final slider = find.descendant(of: tileOf('Desk lamp'), matching: find.byKey(const ValueKey('tile-brightness')));
    final r = tester.getRect(slider);
    await tester.tapAt(Offset(r.left + r.width * 0.2, r.center.dy));
    await tester.pumpUntil(() => desk.state.brightness! < 90);
    expect(world.central.bulbs['b2']!.state.on, isFalse, reason: 'only that light changes');
  });

  e2e('a Bluetooth issue snack bar goes once the issue is gone', (tester, world) async {
    world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await world.home.setDebugLogging(true);

    world.central.permissionGranted = false;
    world.central.dropConnection('b1');
    await world.launch(tester);
    final issue = find.byKey(const ValueKey('bluetooth-issue'));
    await tester.pumpUntilFound(issue);
    expect(
      world.log.entries.where((e) => e.level == LogLevel.debug && e.message.startsWith('showing Bluetooth issue')),
      isNotEmpty,
    );

    // Granted outside the app; adding a light finds Bluetooth ready again.
    world.central.permissionGranted = true;
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.pumpUntilGone(issue);
    expect(world.log.entries.where((e) => e.message == 'Bluetooth issue gone, hiding its snack bar'), hasLength(1));
  });

  e2e('rename a profile, or cancel and keep its name', (tester, world) async {
    await twoBulbs(tester, world);
    await tester.tapAndSettle(find.text('Profiles'));
    await tester.pumpUntilFound(find.text('Energise'));

    await tester.tapAndSettle(find.byKey(const ValueKey('profile-menu-Energise')));
    await tester.tapAndSettle(find.text('Rename'));
    await tester.tapAndSettle(find.widgetWithText(TextButton, 'Cancel'));
    expect(find.byType(RenameDialog), findsNothing);
    expect(world.home.profiles.where((p) => p.name == 'Energise'), hasLength(1));

    await tester.tapAndSettle(find.byKey(const ValueKey('profile-menu-Energise')));
    await tester.tapAndSettle(find.text('Rename'));
    await tester.enterText(find.byType(TextField), 'Wake up');
    await tester.pump();
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpUntilFound(find.text('Wake up'));
    expect(find.text('Energise'), findsNothing);
    expect(world.home.profiles.where((p) => p.name == 'Wake up'), hasLength(1));
  });

  e2e('the star puts a profile on Home and takes it off again', (tester, world) async {
    await twoBulbs(tester, world);
    final onHome = find.widgetWithText(ActionChip, 'Energise');
    expect(onHome, findsNothing);
    await tester.tapAndSettle(find.text('Profiles'));
    final energise = find.ancestor(of: find.text('Energise'), matching: find.byType(Card));
    await tester.tapAndSettle(find.descendant(of: energise, matching: find.byTooltip('Show on Home')));
    expect(find.descendant(of: energise, matching: find.byTooltip('Remove from Home')), findsOneWidget);

    await tester.tapAndSettle(find.text('Home'));
    expect(onHome, findsOneWidget);
    await tester.tapAndSettle(onHome);
    await tester.pumpUntil(() => world.central.bulbs.values.every((b) => b.state.on == true));

    await tester.tapAndSettle(find.text('Profiles'));
    await tester.tapAndSettle(find.descendant(of: energise, matching: find.byTooltip('Remove from Home')));
    await tester.tapAndSettle(find.text('Home'));
    expect(onHome, findsNothing);
  });

  e2e('a colour preset goes to a room or single lights, and says where it was approximated', (tester, world) async {
    world.bulb('b3', name: 'Hall', model: 'LTA001');
    await twoBulbs(tester, world);
    await world.addBulbThroughUi(tester, 'Hall');
    await world.home.createRoom('Lounge', ['ble:b1', 'ble:b2']);
    await world.home.savePreset('Ruby', const LightState(on: true, brightness: 200, color: XyColor(0.675, 0.322)));
    await tester.settle(const Duration(milliseconds: 300));
    final desk = world.central.bulbs['b1']!, shelf = world.central.bulbs['b2']!, hall = world.central.bulbs['b3']!;

    await tester.tapAndSettle(find.text('Profiles'));
    await tester.pumpUntilFound(find.text('Ruby'));
    await tester.tapAndSettle(find.text('Ruby'));
    await tester.pumpUntilFound(find.text('Apply to'));
    final apply = find.widgetWithText(FilledButton, 'Apply');
    expect(tester.widget<FilledButton>(apply).onPressed, isNull, reason: 'nothing picked yet');

    await tester.tapAndSettle(chip('Lounge'));
    expect(chipSelected(tester, 'Lounge'), isTrue);
    expect(chipSelected(tester, 'Desk lamp'), isTrue);
    expect(chipSelected(tester, 'Shelf'), isTrue);
    expect(chipSelected(tester, 'Hall'), isFalse);
    expect(chipSelected(tester, 'All lights'), isFalse);

    // Taking one light out of the room unpicks the room's chip.
    await tester.tapAndSettle(chip('Shelf'));
    expect(chipSelected(tester, 'Lounge'), isFalse);
    await tester.tapAndSettle(chip('Shelf'));
    expect(chipSelected(tester, 'Lounge'), isTrue);

    await tester.tapAndSettle(apply);
    await tester.pumpUntil(() => desk.state.color is XyColor && shelf.state.on == true);
    expect(shelf.state.color, isA<WhiteColor>(), reason: 'the white bulb gets the closest white');
    expect(hall.state.on, isFalse);
    expect(find.text('Applied Ruby. Approximated on 1 light.'), findsOneWidget);

    await tester.tapAndSettle(find.text('Ruby'));
    await tester.pumpUntilFound(find.text('Apply to'));
    await tester.tapAndSettle(chip('All lights'));
    await tester.tapAndSettle(chip('Lounge'));
    expect(chipSelected(tester, 'Hall'), isTrue);
    expect(chipSelected(tester, 'Desk lamp'), isFalse);
    await tester.tapAndSettle(chip('Shelf'));
    await tester.tapAndSettle(apply);
    await tester.pumpUntil(() => hall.state.on == true);
    expect(find.text('Applied Ruby. Approximated on 2 lights.'), findsOneWidget);
  });
  e2e('a white preset takes its warmth from the temperature slider', (tester, world) async {
    await world.launch(tester);
    await tester.tapAndSettle(find.text('Profiles'));
    await tester.tapAndSettle(find.byKey(const ValueKey('new-profile')));
    await tester.tapAndSettle(find.text('New colour preset'));
    await tester.enterText(find.byKey(const ValueKey('profile-name')), 'Candlelight');
    await tester.tapAndSettle(find.text('White'));
    expect(find.byKey(const ValueKey('color-wheel')), findsNothing);
    final slider = find.byKey(const ValueKey('temperature-slider'));
    final r = tester.getRect(slider);
    // Left is warm.
    await tester.tapAt(Offset(r.left + 4, r.center.dy));
    await tester.pump();
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpUntil(() => world.home.profiles.any((p) => p.name == 'Candlelight'));
    final preset = world.home.profiles.firstWhere((p) => p.name == 'Candlelight').preset!;
    expect(preset.color, isA<WhiteColor>());
    expect((preset.color! as WhiteColor).mireds, greaterThan(440));
  });
}
