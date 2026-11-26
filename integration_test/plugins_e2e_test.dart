// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/ui/settings_screen.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  Future<void> openPlugins(WidgetTester tester) async {
    await tester.tapAndSettle(find.text('Settings'));
    final settings = find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('plugin-music-sync')), 200, scrollable: settings);
    await tester.settle(const Duration(milliseconds: 300));
  }

  e2e('music sync is an experimental plugin that can be switched off and on again', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Desk lamp')..state = const LightState(on: true, brightness: 120);
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    expect(find.byKey(const ValueKey('open-music-sync')), findsOneWidget);
    world.music.start();
    await tester.pumpUntil(() => bulb.state.brightness == HueRange.maxBrightness, timeout: const Duration(seconds: 15));

    await openPlugins(tester);
    final plugin = find.byKey(const ValueKey('plugin-music-sync'));
    expect(find.descendant(of: plugin, matching: find.text('Experimental')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-music-sync')), findsOneWidget);

    await tester.tapAndSettle(plugin);
    expect(world.plugins.isEnabled('music-sync'), isFalse);
    expect(find.byKey(const ValueKey('settings-music-sync')), findsNothing);
    await tester.pumpUntil(() => bulb.state.brightness == 120);
    expect(world.audio.listening, isNull, reason: 'switching it off stops listening');
    expect(await world.pluginStore.load(), {'music-sync': false});

    await tester.tapAndSettle(find.text('Home'));
    expect(find.byKey(const ValueKey('open-music-sync')), findsNothing);

    // Off survives a restart.
    await world.launch(tester);
    expect(world.plugins.isEnabled('music-sync'), isFalse);
    expect(find.byKey(const ValueKey('open-music-sync')), findsNothing);

    await openPlugins(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('plugin-music-sync')));
    expect(find.byKey(const ValueKey('settings-music-sync')), findsOneWidget);
    await tester.tapAndSettle(find.text('Home'));
    expect(find.byKey(const ValueKey('open-music-sync')), findsOneWidget);
  });

  e2e('the music sync screen says it is experimental', (tester, world) async {
    await world.launch(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('open-music-sync')));
    await tester.pumpUntilFound(find.text('Listen to'));
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Experimental')), findsOneWidget);
  });
}
