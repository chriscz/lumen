// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/log/logger.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';

void main() {
  late SimulatedBleCentral central;
  late SimulatedBridge bridge;
  late Logger log;
  late HomeController home;

  setUp(() async {
    central = SimulatedBleCentral(scanDelay: Duration.zero, latency: const Duration(milliseconds: 5));
    bridge = SimulatedBridge();
    log = Logger.memory();
    home = HomeController(AppServices.simulated(central: central, bridge: bridge, log: log));
    await home.load();
    await home.setDebugLogging(true);
  });

  String text() => log.entries.map((e) => e.message).join('\n');

  test('turning debug logging on keeps debug entries and is persisted', () async {
    expect(log.debugEnabled, isTrue);
    expect(log.persist, isTrue, reason: 'a debug log is kept between runs');
    final again = HomeController(AppServices.simulated(central: central, store: home.services.store));
    await again.load();
    expect(again.debugLogging, isTrue);
    expect(again.log.debugEnabled, isTrue);
  });

  test('turning debug logging off keeps only the last lines again', () async {
    await home.setDebugLogging(false);
    expect(log.persist, isFalse);
  });

  test('a home loaded with debug logging off does not keep the log', () async {
    final fresh = Logger.memory()..persist = true;
    final other = HomeController(AppServices.simulated(central: central, log: fresh));
    await other.load();
    expect(fresh.persist, isFalse);
  });

  test('logs commands, coalescing and rollbacks', () async {
    final bulb = central.addBulb(SimulatedHueBulb(id: 'aa'));
    await home.addBluetoothLight((await home.scanBluetooth().first));
    final first = home.setBrightness('ble:aa', 10);
    final second = home.setBrightness('ble:aa', 20);
    final third = home.setBrightness('ble:aa', 30);
    await Future.wait([first, second, third]);
    expect(text(), contains('command ble:aa'));
    expect(text(), contains('coalesced'));

    bulb.inRange = false;
    central.dropConnection('aa');
    await home.setPower('ble:aa', false);
    expect(log.entries.where((e) => e.level == LogLevel.warning).map((e) => e.message).join(), contains('rolled back'));
  });

  test('bridge calls are logged with the app key redacted', () async {
    bridge.addLight(SimulatedBridgeLight(name: 'Sofa'));
    bridge.pressLinkButton();
    final account = await home.pairBridge('192.168.1.2');
    expect(text(), contains('GET /api/${account.appKey.substring(0, 4)}.../lights'));
    expect(text(), isNot(contains(account.appKey)));
  });
}
