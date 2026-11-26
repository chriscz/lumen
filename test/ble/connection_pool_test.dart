// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/ble/hue_ble_driver.dart';

void main() {
  const latency = Duration(milliseconds: 20);

  /// Drops every open link a moment after the writes went out, while they
  /// are still in flight.
  void dropAllSoon(SimulatedBleCentral central) => Timer(latency ~/ 4, () {
    for (final id in central.connected.toList()) {
      central.dropConnection(id);
    }
  });

  test('a full pool whose busy links all drop still connects one more bulb', () async {
    final central = SimulatedBleCentral(scanDelay: Duration.zero, latency: latency);
    final pool = HueBleDriver(central, maxConnections: 2);
    for (final id in ['a', 'b', 'c']) {
      central.addBulb(SimulatedHueBulb(id: id, bonded: true));
    }
    await pool.add('a');
    await pool.add('b');
    expect(pool.connected, {'a', 'b'});

    final sends = [
      for (final id in ['a', 'b', 'c']) pool.send(id, const LightCommand(on: true)),
    ];
    dropAllSoon(central);
    await Future.wait(sends).timeout(const Duration(seconds: 5));
    for (final id in ['a', 'b', 'c']) {
      expect(central.bulbs[id]!.state.on, isTrue, reason: id);
    }
    expect(pool.connected.length, lessThanOrEqualTo(2));
  });

  test('a room command to one more bulb than the pool holds completes when every link drops', () async {
    final central = SimulatedBleCentral(scanDelay: Duration.zero, latency: latency, maxConnections: 7);
    final home = HomeController(
      AppServices.simulated(central: central, bridge: SimulatedBridge(), store: MemoryHomeStore()),
    );
    await home.load();
    final ids = <String>[];
    for (var i = 0; i < 8; i++) {
      central.addBulb(SimulatedHueBulb(id: 'b$i', name: 'Bulb $i', bonded: true));
      final found = await home.scanBluetooth().firstWhere((b) => b.deviceId == 'b$i');
      ids.add((await home.addBluetoothLight(found)).id);
    }
    final room = await home.createRoom('Hall', ids);
    // b0 was closed to make room for b7: the pool is full of the others.
    expect(central.connected, hasLength(7));

    final command = home.setRoomPower(room.id, true);
    dropAllSoon(central);
    await command.timeout(const Duration(seconds: 5));
    for (var i = 0; i < 8; i++) {
      expect(central.bulbs['b$i']!.state.on, isTrue, reason: 'b$i');
    }
  });
}
