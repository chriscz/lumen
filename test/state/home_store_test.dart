// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/home.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/state/home_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const key = 'home.v1';
  const snapshot = HomeSnapshot(
    lights: [
      Light(
        id: 'ble:aa',
        name: 'Desk',
        transport: Transport.ble,
        address: 'aa',
        kind: LightKind.color,
        state: LightState(on: true, brightness: 120),
        reachable: true,
      ),
    ],
    bridges: [BridgeAccount(id: 'b1', name: 'Hue Bridge', host: '192.168.1.2', appKey: 'secret-key')],
    rooms: [Room(id: 'room-1', name: 'Study')],
    theme: ThemeChoice.light,
    debugLogging: true,
  );

  group('SharedPrefsHomeStore', () {
    test('a first launch, with nothing saved, loads the fresh empty home', () async {
      SharedPreferences.setMockInitialValues({});
      final loaded = await SharedPrefsHomeStore().load();
      expect(loaded.fresh, isTrue);
      expect(loaded.lights, isEmpty);
    });

    test('saves the home as JSON under its key and loads it back', () async {
      SharedPreferences.setMockInitialValues({});
      await SharedPrefsHomeStore().save(snapshot);

      final raw = (await SharedPreferences.getInstance()).getString(key)!;
      expect(jsonDecode(raw), snapshot.toJson());

      final loaded = await SharedPrefsHomeStore().load();
      expect(loaded.fresh, isFalse);
      expect(loaded.lights.single.name, 'Desk');
      expect(loaded.lights.single.state.brightness, 120);
      expect(loaded.bridges.single.appKey, 'secret-key');
      expect(loaded.rooms.single.name, 'Study');
      expect(loaded.theme, ThemeChoice.light);
      expect(loaded.debugLogging, isTrue);
    });

    test('a stored home that is not JSON loads as an empty home, not a first launch', () async {
      SharedPreferences.setMockInitialValues({key: '{"lights": [ cut off'});
      final loaded = await SharedPrefsHomeStore().load();
      expect(loaded.fresh, isFalse, reason: 'a first launch would add the starter profiles over the user data');
      expect(loaded.lights, isEmpty);
      expect(loaded.profiles, isEmpty);
    });

    for (final (what, raw) in [
      ('a list instead of an object', '[1, 2]'),
      ('a light list of the wrong type', '{"lights": 5}'),
      ('a light without its fields', '{"lights": [{"id": 1}]}'),
    ]) {
      test('a stored home with $what loads as an empty home instead of failing', () async {
        SharedPreferences.setMockInitialValues({key: raw});
        final loaded = await SharedPrefsHomeStore().load();
        expect(loaded.fresh, isFalse);
        expect(loaded.lights, isEmpty);
      });
    }
  });

  group('MemoryHomeStore', () {
    test('keeps the same JSON encoding as the app', () async {
      final store = MemoryHomeStore();
      expect((await store.load()).fresh, isTrue);
      await store.save(snapshot);
      expect(jsonDecode(store.json!), snapshot.toJson());
      expect((await store.load()).lights.single.id, 'ble:aa');
    });
  });
}
