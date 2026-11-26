// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  final bar = find.byKey(const ValueKey('reconnect-bar'));

  Future<void> pairSofa(WidgetTester tester, World world) async {
    world.bridge.addLight(SimulatedBridgeLightFactory.sofa());
    await world.launch(tester);
    world.bridge.pressLinkButton();
    await world.home.pairBridge('192.168.1.2');
    await tester.pumpUntilFound(tileOf('Sofa'));
  }

  Future<void> lifecycle(WidgetTester tester, List<AppLifecycleState> states) async {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  e2e('a bridge that drops off shows a reconnect bar, on Home and in a light, until it answers', (tester, world) async {
    await pairSofa(tester, world);
    expect(bar, findsNothing);

    world.bridge.offline = true;
    // The next poll finds the bridge gone.
    await tester.pumpUntilFound(bar, timeout: const Duration(seconds: 15));
    expect(find.text('Reconnecting to Hallway bridge...'), findsOneWidget);
    expect(find.descendant(of: bar, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
    expect(tileOf('Sofa'), findsOneWidget, reason: 'Home is still there under the bar');

    await tester.tapAndSettle(find.text('Sofa'));
    expect(bar, findsOneWidget, reason: 'the bar shows over every screen');

    world.bridge.offline = false;
    await tester.pumpUntilGone(bar, timeout: const Duration(seconds: 40));
    expect(world.home.offlineBridges, isEmpty);
    expect(world.home.light(world.home.lights.single.id)!.reachable, isTrue);
  });

  e2e('retries stop in the background and start over on return', (tester, world) async {
    await pairSofa(tester, world);
    world.bridge.offline = true;
    await tester.pumpUntilFound(bar, timeout: const Duration(seconds: 15));
    final id = world.home.bridges.single.id;

    await lifecycle(tester, [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);
    final attempts = world.home.reconnectAttempts(id);
    await tester.settle(const Duration(minutes: 2));
    expect(world.home.reconnectAttempts(id), attempts, reason: 'nothing is tried in the background');

    world.bridge.offline = false;
    await lifecycle(tester, [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);
    await tester.pumpUntilGone(bar, timeout: const Duration(seconds: 3));
  });
}
