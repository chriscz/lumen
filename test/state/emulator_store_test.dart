// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/emulator/emulator_settings.dart';
import 'package:lumen/state/emulator_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedPrefsEmulatorStore', () {
    test('a first launch has nothing saved', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await SharedPrefsEmulatorStore().load(), isNull);
    });

    test('saved settings load back, paired apps included', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = EmulatorSettings(mac: 'aa:bb:cc:dd:ee:ff', name: 'Upstairs')
        ..enabled = true
        ..announce = false
        ..lightIds['light-1'] = 3
        ..users['key1'] = PairedApp(username: 'key1', devicetype: 'a#b', created: DateTime.utc(2026, 1, 2));
      await SharedPrefsEmulatorStore().save(settings);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('emulator.v1'), contains('"Upstairs"'));
      final loaded = (await SharedPrefsEmulatorStore().load())!;
      expect(loaded.mac, 'aa:bb:cc:dd:ee:ff');
      expect(loaded.name, 'Upstairs');
      expect(loaded.enabled, isTrue);
      expect(loaded.announce, isFalse);
      expect(loaded.lightIds, {'light-1': 3});
      expect(loaded.users['key1']!.devicetype, 'a#b');
    });

    test('settings that cannot be read count as none, so the app starts fresh', () async {
      for (final raw in ['{not json', '[1, 2]', '{"name": 5}']) {
        SharedPreferences.setMockInitialValues({'emulator.v1': raw});
        expect(await SharedPrefsEmulatorStore().load(), isNull, reason: raw);
      }
    });
  });
}
