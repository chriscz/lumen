// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/sim/simulated_bridge_platform.dart';

void main() {
  test('the simulated system mDNS records what is registered and can fail', () async {
    final nsd = SimulatedSystemMdns();
    expect(nsd.available, isTrue);
    expect(await nsd.register(name: 'Lumen-DDEEFF', port: 1818, txt: {'bridgeid': 'x'}), isNull);
    expect(
      [nsd.registered?.name, nsd.registered?.port, nsd.registered?.txt],
      [
        'Lumen-DDEEFF',
        1818,
        {'bridgeid': 'x'},
      ],
    );
    await nsd.unregister();
    expect(nsd.registered, isNull);
    nsd.failWith = 'NsdManager error 3';
    expect(await nsd.register(name: 'n', port: 1, txt: const {}), 'NsdManager error 3');
    expect(nsd.registered, isNull);
    expect(nsd.calls, ['register', 'unregister', 'register']);
    expect(SimulatedSystemMdns(available: false).available, isFalse);
  });

  test('the simulated background service records runs, stops and requests', () async {
    final service = SimulatedBridgeBackground();
    expect(service.supported, isTrue);
    expect(service.running, isFalse);
    await service.run(text: 'Listening', stayAwakeWhileCharging: true);
    expect(service.running, isTrue);
    expect(service.text, 'Listening');
    expect(service.stayAwakeWhileCharging, isTrue);
    await service.stop();
    expect(service.running, isFalse);
    expect(await service.requestNotifications(), isFalse, reason: 'denied by default');
    service.notificationsGranted = true;
    expect(await service.requestNotifications(), isTrue);
    expect(await service.openBatterySettings(), isTrue);
    expect(service.calls, ['run', 'stop', 'requestNotifications', 'requestNotifications', 'openBatterySettings']);
  });
}
