// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/domain/errors.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/bridge/hue_bridge_client.dart';

/// Two bridges behind clients that can drop off the network, with every
/// light read counted.
class _Net {
  final hall = SimulatedBridge(id: '001788fffe000001', name: 'Hall');
  final attic = SimulatedBridge(id: '001788fffe000002', name: 'Attic');
  final Set<String> down = {};
  final Map<String, int> reads = {};

  SimulatedBridge _at(String host) => host == '192.168.1.2' ? hall : attic;

  HueBridgeClient client(String host) => HueBridgeClient(
    MockClient((request) async {
      if (down.contains(host)) throw http.ClientException('no route to host');
      if (request.method == 'GET' && request.url.path.endsWith('/lights')) reads[host] = (reads[host] ?? 0) + 1;
      final (status, body) = _at(host).handle(request.method, request.url.path, request.body);
      return http.Response(jsonEncode(body), status);
    }),
    Uri.parse('http://$host'),
  );
}

void main() {
  late _Net net;
  late HomeController home;
  late List<LightError> errors;

  /// Runs [body] in fake time with a controller paired to the hall bridge.
  void run(void Function(FakeAsync async) body) => fakeAsync((async) {
    net = _Net();
    net.hall.addLight(SimulatedBridgeLight(name: 'Sofa'));
    net.attic.addLight(SimulatedBridgeLight(name: 'Desk'));
    home = HomeController(
      AppServices(central: SimulatedBleCentral(), bridgeClient: net.client, store: MemoryHomeStore()),
    );
    errors = [];
    home.errors.listen(errors.add);
    home.load();
    async.flushMicrotasks();
    net.hall.pressLinkButton();
    home.pairBridge('192.168.1.2', interval: Duration.zero);
    async.flushMicrotasks();
    body(async);
    home.dispose();
  });

  String sofa() => HomeController.bridgeLightId(net.hall.id, '1');

  test('a bridge that drops off the network is offline, retried with backoff, and back when it answers', () {
    run((async) {
      expect(home.offlineBridges, isEmpty);
      net.down.add('192.168.1.2');
      home.refresh(quiet: true);
      async.flushMicrotasks();
      expect(home.offlineBridges, {net.hall.id});
      expect(home.light(sofa())!.reachable, isFalse);

      // Retries come after 1, 2, 4, 8, 16, then every 30 seconds.
      var tries = 0;
      final waits = <int>[];
      var waited = 0;
      final before = net.reads['192.168.1.2'] ?? 0;
      for (var second = 1; second <= 91; second++) {
        async.elapse(const Duration(seconds: 1));
        waited++;
        final attempts = home.reconnectAttempts(net.hall.id);
        if (attempts > tries) {
          tries = attempts;
          waits.add(waited);
          waited = 0;
        }
      }
      expect(waits, [1, 2, 4, 8, 16, 30, 30]);
      expect(net.reads['192.168.1.2'] ?? 0, before, reason: 'nothing got through while down');

      net.hall.lights['1']!.state = const LightState(on: true, brightness: 99);
      net.down.clear();
      async.elapse(const Duration(seconds: 30));
      expect(home.offlineBridges, isEmpty);
      expect(home.light(sofa())!.reachable, isTrue);
      expect(home.light(sofa())!.state.brightness, 99, reason: 'its lights were read again');
      final reads = net.reads['192.168.1.2'];
      async.elapse(const Duration(minutes: 5));
      expect(net.reads['192.168.1.2'], reads, reason: 'no more retries once it is back');
    });
  });

  test('a failed command still fails, and marks the bridge offline', () {
    run((async) {
      net.down.add('192.168.1.2');
      Object? failure;
      home.setPower(sofa(), true).catchError((Object e) => failure = e);
      async.elapse(const Duration(milliseconds: 10));
      expect(failure, isNull, reason: 'the action reports through the error stream');
      expect(errors.single, isA<BridgeOffline>());
      expect(home.light(sofa())!.isOn, isFalse, reason: 'rolled back');
      expect(home.offlineBridges, {net.hall.id});

      net.down.clear();
      async.elapse(const Duration(seconds: 1));
      expect(home.offlineBridges, isEmpty);
    });
  });

  test('a command that gets through brings an offline bridge back at once', () {
    run((async) {
      net.down.add('192.168.1.2');
      home.refresh(quiet: true);
      async.flushMicrotasks();
      expect(home.offlineBridges, {net.hall.id});
      net.down.clear();
      home.setPower(sofa(), true);
      async.flushMicrotasks();
      expect(home.offlineBridges, isEmpty);
    });
  });

  test('a bridge that answers with an error is not offline', () {
    run((async) {
      net.hall.failAll = true;
      home.refresh();
      async.flushMicrotasks();
      expect(errors.single, isA<BridgeUnreachable>());
      expect(home.offlineBridges, isEmpty);
      async.elapse(const Duration(minutes: 1));
      expect(home.reconnectAttempts(net.hall.id), 0);
    });
  });

  test('retries stop while the app is in the background and start again on return', () {
    run((async) {
      net.down.add('192.168.1.2');
      home.refresh(quiet: true);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 3));
      expect(home.reconnectAttempts(net.hall.id), 2);

      home.setForeground(false);
      async.elapse(const Duration(minutes: 10));
      expect(home.reconnectAttempts(net.hall.id), 2, reason: 'no retries in the background');
      expect(home.offlineBridges, {net.hall.id}, reason: 'still offline');

      // A bridge failing in the background is not retried either.
      home.refresh(quiet: true);
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 1));
      expect(home.reconnectAttempts(net.hall.id), 2);

      home.setForeground(true);
      net.down.clear();
      async.elapse(const Duration(seconds: 1));
      expect(home.offlineBridges, isEmpty, reason: 'the backoff starts over at one second');
    });
  });

  test('two bridges go offline and come back on their own', () {
    run((async) {
      net.attic.pressLinkButton();
      home.pairBridge('192.168.1.3', interval: Duration.zero);
      async.flushMicrotasks();
      net.down.addAll(['192.168.1.2', '192.168.1.3']);
      home.refresh(quiet: true);
      async.flushMicrotasks();
      expect(home.offlineBridges, {net.hall.id, net.attic.id});
      net.down.remove('192.168.1.3');
      async.elapse(const Duration(seconds: 1));
      expect(home.offlineBridges, {net.hall.id});
    });
  });

  test('forgetting an offline bridge stops its retries', () {
    run((async) {
      net.down.add('192.168.1.2');
      home.refresh(quiet: true);
      async.flushMicrotasks();
      unawaited(home.forgetBridge(net.hall.id));
      async.flushMicrotasks();
      expect(home.offlineBridges, isEmpty);
      async.elapse(const Duration(minutes: 1));
      expect(home.reconnectAttempts(net.hall.id), 0);
    });
  });
}
