// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/emulator/emulator_settings.dart';

void main() {
  EmulatorSettings roundTrip(EmulatorSettings s) =>
      EmulatorSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>);

  test('the background, wake and discovery settings default to the low-power, announcing choice', () {
    final s = EmulatorSettings(mac: 'aa:bb:cc:dd:ee:ff');
    expect(s.background, isTrue);
    expect(s.stayAwakeWhileCharging, isFalse);
    expect(s.mdnsEnabled, isTrue);
    expect(s.ssdpEnabled, isTrue);
    expect(s.mdnsImplementation, isNull, reason: 'the platform default');
  });

  test('older saved settings without the new fields read as the defaults', () {
    final s = EmulatorSettings.fromJson({'mac': 'aa:bb:cc:dd:ee:ff'});
    expect([s.background, s.stayAwakeWhileCharging, s.mdnsEnabled, s.ssdpEnabled], [true, false, true, true]);
    expect(s.mdnsImplementation, isNull);
  });

  test('the new settings survive a save and load', () {
    final s = EmulatorSettings(mac: 'aa:bb:cc:dd:ee:ff')
      ..background = false
      ..stayAwakeWhileCharging = true
      ..mdnsEnabled = false
      ..ssdpEnabled = false
      ..mdnsImplementation = MdnsImplementation.builtIn;
    final back = roundTrip(s);
    expect(
      [back.background, back.stayAwakeWhileCharging, back.mdnsEnabled, back.ssdpEnabled],
      [false, true, false, false],
    );
    expect(back.mdnsImplementation, MdnsImplementation.builtIn);
    expect(
      roundTrip(back..mdnsImplementation = MdnsImplementation.system).mdnsImplementation,
      MdnsImplementation.system,
    );
  });

  test('an unknown mDNS implementation reads as the platform default', () {
    final s = EmulatorSettings.fromJson({'mac': 'aa:bb:cc:dd:ee:ff', 'mdnsImplementation': 'carrier-pigeon'});
    expect(s.mdnsImplementation, isNull);
  });

  test('the platform default is the system mDNS where it exists, else the built-in one', () {
    final s = EmulatorSettings(mac: 'aa:bb:cc:dd:ee:ff');
    expect(s.mdnsWanted(systemAvailable: true), MdnsImplementation.system);
    expect(s.mdnsWanted(systemAvailable: false), MdnsImplementation.builtIn);
    s.mdnsImplementation = MdnsImplementation.builtIn;
    expect(s.mdnsWanted(systemAvailable: true), MdnsImplementation.builtIn);
    s.mdnsImplementation = MdnsImplementation.system;
    expect(s.mdnsWanted(systemAvailable: false), MdnsImplementation.builtIn, reason: 'only built-in exists');
  });

  test('a paired app is active when it was seen within the window', () {
    final now = DateTime.utc(2026, 10, 24, 12);
    final app = PairedApp(username: 'k', devicetype: 'd', created: now.subtract(const Duration(days: 1)));
    expect(app.activeAt(now), isFalse, reason: 'never seen');
    expect(app.used(now.subtract(const Duration(minutes: 4))).activeAt(now), isTrue);
    expect(app.used(now.subtract(const Duration(minutes: 6))).activeAt(now), isFalse);
    expect(PairedApp.activeWindow, const Duration(minutes: 5));
  });
}
