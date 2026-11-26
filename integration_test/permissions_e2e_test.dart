// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

final _issue = find.byKey(const ValueKey('bluetooth-issue'));

void main() {
  initE2eBinding();

  e2e('a missing permission at launch shows one snack bar and never prompts on its own', (tester, world) async {
    world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    final before = world.central.permissionRequests;

    world.central.permissionGranted = false;
    world.central.dropConnection('b1');
    await world.launch(tester);
    await tester.pumpUntilFound(_issue);
    expect(find.textContaining('Nearby devices'), findsOneWidget);

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.settle(const Duration(seconds: 3));
    expect(_issue, findsOneWidget, reason: 'the same snack bar is not shown twice');
    expect(world.central.permissionRequests, before, reason: 'no prompt without a user action');

    await tester.tapAndSettle(find.widgetWithText(SnackBarAction, 'Retry'));
    expect(world.central.permissionRequests, before + 1);
    await tester.pumpUntilFound(_issue);

    world.central.permissionGranted = true;
    await tester.tapAndSettle(find.widgetWithText(SnackBarAction, 'Retry'));
    await tester.pumpUntilGone(_issue);
    await tester.pumpUntil(() => world.central.connected.contains('b1'));
  });

  e2e('Add light asks for the permission once per launch', (tester, world) async {
    world.central.permissionGranted = false;
    await world.launch(tester);
    expect(world.central.permissionRequests, 0);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.pumpUntilFound(_issue);
    expect(world.central.permissionRequests, 1);
    await tester.pageBack();
    await tester.settle(const Duration(seconds: 1));
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.settle(const Duration(seconds: 1));
    expect(world.central.permissionRequests, 1);
  });

  e2e('a permanently denied permission offers to open the app settings', (tester, world) async {
    final calls = <String>[];
    const channel = MethodChannel('lumen/settings');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    world.central
      ..permissionGranted = false
      ..permanentlyDenied = true;
    await world.launch(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.pumpUntilFound(find.widgetWithText(SnackBarAction, 'Open settings'));
    await tester.tapAndSettle(find.widgetWithText(SnackBarAction, 'Open settings'));
    expect(calls, ['openAppSettings']);
  });

  e2e('Bluetooth off shows a snack bar whose Retry turns it on', (tester, world) async {
    world.central.available = false;
    await world.launch(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('add-light')));
    await tester.pumpUntilFound(find.textContaining('Bluetooth is off'));
    world.central.available = true;
    await tester.tapAndSettle(find.widgetWithText(SnackBarAction, 'Retry'));
    await tester.pumpUntilGone(_issue);
  });
}
