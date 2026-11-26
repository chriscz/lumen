// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/ui/group_detail_screen.dart';
import 'package:lumen/ui/light_detail_screen.dart';
import 'package:lumen/ui/room_editor_screen.dart';
import 'package:lumen/ui/widgets/light_controls.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  /// Three bulbs on Home, by default the first two in a group named Lounge.
  Future<void> lounge(
    WidgetTester tester,
    World world, {
    bool linked = false,
    List<String> members = const ['ble:b1', 'ble:b2'],
  }) async {
    world.bulb('b1', name: 'Desk lamp');
    world.bulb('b2', name: 'Floor lamp');
    world.bulb('b3', name: 'Shelf', model: 'LTA001');
    await world.launch(tester);
    for (final n in ['Desk lamp', 'Floor lamp', 'Shelf']) {
      await world.addBulbThroughUi(tester, n);
    }
    await world.home.createRoom('Lounge', members, linked: linked);
    await tester.settle(const Duration(milliseconds: 300));
  }

  Future<void> openLounge(WidgetTester tester) async {
    await tester.tapAndSettle(find.byKey(const ValueKey('room-header-Lounge')));
    await tester.pumpUntilFound(find.byKey(const ValueKey('group-detail')));
  }

  Finder groupScrollable() =>
      find.descendant(of: find.byType(GroupDetailScreen), matching: find.byType(Scrollable)).first;

  Future<void> scrollGroupToEnd(WidgetTester tester) async {
    final position = tester.state<ScrollableState>(groupScrollable()).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.settle(const Duration(milliseconds: 300));
  }

  e2e('edit a group from its screen: rename it and take a light out', (tester, world) async {
    await lounge(tester, world);
    await world.home.createRoom('Study', ['ble:b3']);
    await tester.settle(const Duration(milliseconds: 300));
    await openLounge(tester);
    await tester.tapAndSettle(find.byTooltip('Edit group'));
    await tester.pumpUntilFound(find.byType(RoomEditorScreen));
    expect(find.text('Edit group'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('room-name'))).controller!.text, 'Lounge');
    expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Desk lamp')).value, isTrue);
    expect(find.text('In Study'), findsOneWidget, reason: 'a light in another group says where it is');

    await tester.enterText(find.byKey(const ValueKey('room-name')), ' Den ');
    await tester.tapAndSettle(find.widgetWithText(CheckboxListTile, 'Floor lamp'));
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpUntilGone(find.byType(RoomEditorScreen));

    final room = world.home.rooms.singleWhere((r) => r.name != 'Study');
    expect(room.name, 'Den', reason: 'the name is trimmed');
    expect(world.home.lightsIn(room.id).map((l) => l.name), ['Desk lamp']);
    expect(find.text('1 light'), findsOneWidget, reason: 'the group screen follows the edit');
  });

  e2e('deleting a group from its editor goes back Home and keeps its lights', (tester, world) async {
    await lounge(tester, world);
    await openLounge(tester);
    await tester.tapAndSettle(find.byTooltip('Edit group'));
    await tester.tapAndSettle(find.byTooltip('Delete group'));
    await tester.pumpUntilGone(find.byType(RoomEditorScreen));
    expect(find.byType(GroupDetailScreen), findsNothing);
    expect(find.byKey(const ValueKey('room-header-Lounge')), findsNothing);
    expect(world.home.rooms, isEmpty);
    expect(tileOf('Desk lamp'), findsOneWidget);
    expect(tileOf('Floor lamp'), findsOneWidget);
  });

  e2e('group swatches set a white on every light, then a colour on those that can show it', (tester, world) async {
    await lounge(tester, world, members: ['ble:b1', 'ble:b2', 'ble:b3']);
    await openLounge(tester);
    expect(find.byKey(const ValueKey('color-wheel')), findsOneWidget, reason: 'a group with colour opens on colour');
    await tester.tapAndSettle(find.text('White'));
    expect(find.byKey(const ValueKey('color-wheel')), findsNothing);
    expect(find.byType(TemperatureSlider), findsOneWidget);
    await tester.tapAndSettle(find.text('Colour'));
    expect(find.byKey(const ValueKey('color-wheel')), findsOneWidget);
    expect(find.byType(TemperatureSlider), findsNothing);
    final swatches = find.descendant(of: find.byType(Swatches), matching: find.byType(InkResponse));

    await scrollGroupToEnd(tester);
    await tester.tapAndSettle(swatches.at(1));
    await tester.pumpUntil(() => world.central.bulbs.values.every((b) => b.state.color == const WhiteColor(366)));
    expect(find.byType(TemperatureSlider), findsOneWidget);
    expect(find.byKey(const ValueKey('color-wheel')), findsNothing);

    await scrollGroupToEnd(tester);
    await tester.tapAndSettle(swatches.at(7));
    await tester.pumpUntil(
      () => [world.central.bulbs['b1']!, world.central.bulbs['b2']!].every((b) => b.state.color is XyColor),
    );
    expect(world.central.bulbs['b3']!.state.color, isA<WhiteColor>(), reason: 'the white bulb keeps a white');
    expect(find.byKey(const ValueKey('color-wheel')), findsOneWidget);
  });

  e2e('a light in the group list opens its own screen', (tester, world) async {
    await lounge(tester, world);
    await openLounge(tester);
    await scrollGroupToEnd(tester);
    await tester.tapAndSettle(find.widgetWithText(ListTile, 'Floor lamp'));
    await tester.pumpUntilFound(find.byType(LightDetailScreen));
    expect(tester.widget<LightDetailScreen>(find.byType(LightDetailScreen)).lightId, 'ble:b2');
  });

  e2e('a detached light of a cluster rejoins from the cluster screen', (tester, world) async {
    await lounge(tester, world, linked: true);
    final desk = world.central.bulbs['b1']!, floor = world.central.bulbs['b2']!;
    await tester.tapAndSettle(powerSwitchOf('Lounge'));
    await tester.pumpUntil(() => desk.state.on == true && floor.state.on == true);
    await tester.tapAndSettle(powerSwitchOf('Desk lamp'));
    await tester.pumpUntil(() => desk.state.on == false && world.home.isDetached('ble:b1'));

    await tester.tapAndSettle(find.text('Lounge').first);
    await tester.pumpUntilFound(find.byKey(const ValueKey('group-detail')));
    expect(find.text('2 lights, linked'), findsOneWidget);
    await scrollGroupToEnd(tester);
    expect(find.text('Off, detached'), findsOneWidget);
    expect(find.text('On'), findsOneWidget);

    await tester.tapAndSettle(find.widgetWithText(TextButton, 'Rejoin'));
    await tester.pumpUntil(() => !world.home.isDetached('ble:b1') && desk.state.on == true);
    await tester.pumpUntilGone(find.widgetWithText(TextButton, 'Rejoin'));
    expect(find.text('Off, detached'), findsNothing);
  });
}
