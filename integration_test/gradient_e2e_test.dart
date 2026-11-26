// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/capabilities.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  Future<void> reveal(WidgetTester tester, Finder finder) =>
      tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);

  e2e('edit the colours and mode of a gradient strip', (tester, world) async {
    final strip = world.bulb('s1', name: 'TV strip', model: 'LCX004');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'TV strip');
    await tester.tapAndSettle(find.text('TV strip'));

    final firstStop = find.byKey(const ValueKey('gradient-stop-0'));
    await reveal(tester, firstStop);
    expect(find.byKey(const ValueKey('gradient-stop-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('gradient-stop-3')), findsNothing);

    // Tap the first stop and pick a green on the wheel. Hue runs clockwise
    // from red at the right edge, so green (hue 120) is low on the left.
    await tester.tapAndSettle(firstStop);
    final wheel = tester.getRect(find.byKey(const ValueKey('gradient-wheel')));
    await tester.tapAt(Offset(wheel.center.dx - wheel.width * 0.18, wheel.center.dy + wheel.height * 0.32));
    await tester.pump();
    final writes = strip.writes.length;
    await tester.tapAndSettle(find.byKey(const ValueKey('gradient-done')));
    await tester.pumpUntil(() => strip.state.gradient != null);
    expect(strip.writes.length - writes, 1, reason: 'one combined write');
    final sent = HueBleCodec.decodeControl(strip.writes.last.value);
    expect(sent.on, isTrue, reason: 'power travels with the palette');
    expect(strip.state.gradient!.colors, hasLength(3));
    expect(
      strip.state.gradient!.colors[0].y,
      greaterThan(0.4),
      reason: 'a green or yellow, got ${strip.state.gradient}',
    );

    await tester.tapAndSettle(find.byKey(const ValueKey('gradient-add')));
    await tester.pumpUntil(() => strip.state.gradient!.colors.length == 4);
    await tester.tapAndSettle(find.byKey(const ValueKey('gradient-mode-mirrored')));
    await tester.pumpUntil(() => strip.state.gradient!.mode == GradientMode.mirrored);
    expect(strip.state.gradient!.colors, hasLength(4));
    await tester.tapAndSettle(find.byKey(const ValueKey('gradient-remove')));
    await tester.pumpUntil(() => strip.state.gradient!.colors.length == 3);
  });

  e2e('only the gradient modes the strip lists are offered', (tester, world) async {
    // Colour light, flags with gradient (bit 3), modes interpolated and segmented.
    world.central.addBulb(
      SimulatedHueBulb(
        id: 's1',
        name: 'TV strip',
        capabilities: [0x00, 0x01, 0x03, 0x03, 0x01, 0x08, 0x08, 0x01, 0x09],
      ),
    );
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'TV strip');
    await tester.tapAndSettle(find.text('TV strip'));
    await reveal(tester, find.byKey(const ValueKey('gradient-mode-segmented')));
    expect(find.byKey(const ValueKey('gradient-mode-interpolated')), findsOneWidget);
    expect(find.byKey(const ValueKey('gradient-mode-mirrored')), findsNothing);
    expect(find.byKey(const ValueKey('gradient-mode-random')), findsNothing);
  });

  e2e('a bulb without gradient support has no gradient section', (tester, world) async {
    world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await tester.tapAndSettle(find.text('Desk lamp'));
    await reveal(tester, find.text('Effects'));
    expect(find.byKey(const ValueKey('gradient-card')), findsNothing);
  });
}
