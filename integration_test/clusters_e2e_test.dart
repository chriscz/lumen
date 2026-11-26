import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  Future<void> linkPair(WidgetTester tester, World world) async {
    world.bulb('b1', name: 'Left strip');
    world.bulb('b2', name: 'Right strip');
    world.bulb('b3', name: 'Desk lamp');
    await world.launch(tester);
    for (final n in ['Left strip', 'Right strip', 'Desk lamp']) {
      await world.addBulbThroughUi(tester, n);
    }
    await tester.longPress(tileOf('Left strip'));
    await tester.settle(const Duration(milliseconds: 300));
    await tester.tapAndSettle(tileOf('Right strip'));
    await tester.tapAndSettle(find.byKey(const ValueKey('link-selected')));
    await tester.enterText(find.byType(TextField), 'TV backlight');
    await tester.pump();
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpUntilFound(tileOf('TV backlight'));
  }

  Finder rejoinOf(String name) => find.descendant(of: tileOf(name), matching: find.byKey(const ValueKey('rejoin')));

  e2e('a cluster acts as one light while its lights stay visible', (tester, world) async {
    await linkPair(tester, world);
    expect(tileOf('Left strip'), findsOneWidget);
    expect(tileOf('Right strip'), findsOneWidget);

    await tester.tapAndSettle(powerSwitchOf('TV backlight'));
    await tester.pumpUntil(
      () => world.central.bulbs['b1']!.state.on == true && world.central.bulbs['b2']!.state.on == true,
    );
    expect(world.central.bulbs['b3']!.state.on, isFalse);

    // Collapse and expand the cluster.
    await tester.tapAndSettle(find.byKey(const ValueKey('cluster-expand')));
    expect(tileOf('Left strip'), findsNothing);
    await tester.tapAndSettle(find.byKey(const ValueKey('cluster-expand')));
    expect(tileOf('Left strip'), findsOneWidget);
  });

  e2e('touching a light detaches it; rejoin and reset bring it back', (tester, world) async {
    await linkPair(tester, world);
    final left = world.central.bulbs['b1']!, right = world.central.bulbs['b2']!;
    await tester.tapAndSettle(powerSwitchOf('TV backlight'));
    await tester.pumpUntil(() => left.state.on == true && right.state.on == true);

    // Switching one strip off on its own detaches it from the cluster.
    await tester.tapAndSettle(powerSwitchOf('Left strip'));
    await tester.pumpUntil(() => left.state.on == false);
    await tester.pumpUntilFound(rejoinOf('Left strip'));

    // The cluster now leaves it alone.
    final slider = find.descendant(of: tileOf('TV backlight'), matching: find.byType(Slider));
    final r = tester.getRect(slider);
    await tester.tapAt(Offset(r.left + r.width * 0.3, r.center.dy));
    await tester.pumpUntil(() => right.state.brightness! < 140);
    expect(left.state.on, isFalse);

    // Rejoin: the strip takes the cluster's settings again.
    await tester.tapAndSettle(rejoinOf('Left strip'));
    await tester.pumpUntil(() => left.state.on == true && left.state.brightness == right.state.brightness);
    expect(rejoinOf('Left strip'), findsNothing);

    // Detach both, then reset the cluster.
    await tester.tapAndSettle(powerSwitchOf('Left strip'));
    await tester.tapAndSettle(powerSwitchOf('Right strip'));
    await tester.pumpUntil(() => left.state.on == false && right.state.on == false);
    await tester.tapAndSettle(find.byKey(const ValueKey('cluster-reset')));
    await tester.pumpUntil(() => left.state.on == true && right.state.on == true);
    expect(find.byKey(const ValueKey('cluster-reset')), findsNothing);
  });

  e2e('all off switches a cluster off too', (tester, world) async {
    await linkPair(tester, world);
    await tester.tapAndSettle(powerSwitchOf('TV backlight'));
    await tester.pumpUntil(() => world.central.bulbs['b1']!.state.on == true);

    await tester.tapAndSettle(find.byKey(const ValueKey('all-off')));
    await tester.pumpUntil(() => world.central.bulbs.values.every((b) => b.state.on == false));
    expect(tester.widget<Switch>(powerSwitchOf('TV backlight')).value, isFalse);
  });

  e2e('unlink a cluster back into a plain group', (tester, world) async {
    await linkPair(tester, world);
    await tester.tapAndSettle(find.text('TV backlight').first);
    await tester.pumpUntilFound(find.byKey(const ValueKey('group-detail')));
    await tester.tapAndSettle(find.byKey(const ValueKey('unlink-cluster')));
    await tester.pumpUntilFound(find.byKey(const ValueKey('room-header-TV backlight')));
    expect(tileOf('TV backlight'), findsNothing);
  });

  e2e('a cluster survives a restart', (tester, world) async {
    world.bulb('b1', name: 'Left strip');
    world.bulb('b2', name: 'Right strip');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Left strip');
    await world.addBulbThroughUi(tester, 'Right strip');
    await world.home.createRoom('TV backlight', ['ble:b1', 'ble:b2'], linked: true);
    await world.launch(tester);
    await tester.pumpUntilFound(tileOf('TV backlight'));
    expect(tileOf('Left strip'), findsOneWidget);
  });
}
