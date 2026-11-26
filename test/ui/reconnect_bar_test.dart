// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/domain/home.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/bridge/hue_bridge_client.dart';
import 'package:lumen/ui/home_scope.dart';
import 'package:lumen/ui/reconnect_bar.dart';

void main() {
  testWidgets('one bar names the bridge, or counts several, and keeps the screen under it', (tester) async {
    final store = MemoryHomeStore();
    await store.save(
      const HomeSnapshot(
        bridges: [
          BridgeAccount(id: 'a', name: 'Hall', host: '192.168.1.2', appKey: 'k'),
          BridgeAccount(id: 'b', name: 'Attic', host: '192.168.1.3', appKey: 'k'),
        ],
      ),
    );
    final down = <String>{};
    final home = HomeController(
      AppServices(
        central: SimulatedBleCentral(),
        bridgeClient: (host) => HueBridgeClient(
          MockClient((_) async {
            if (down.contains(host)) throw http.ClientException('no route');
            return http.Response('{}', 200);
          }),
          Uri.parse('http://$host'),
        ),
        store: store,
      ),
    );
    await home.load();
    await tester.pumpWidget(
      HomeScope(
        home: home,
        child: MaterialApp(
          builder: (context, child) => ReconnectBar(child: child!),
          home: Scaffold(appBar: AppBar(title: const Text('Screen'))),
        ),
      ),
    );
    final bar = find.byKey(const ValueKey('reconnect-bar'));
    expect(bar, findsNothing);
    final state = tester.state(find.byType(Scaffold));

    down.add('192.168.1.2');
    await home.refresh(quiet: true);
    await tester.pump();
    expect(find.text('Reconnecting to Hall...'), findsOneWidget);
    expect(tester.state(find.byType(Scaffold)), same(state), reason: 'the screen under the bar keeps its state');

    down.add('192.168.1.3');
    await home.refresh(quiet: true);
    await tester.pump();
    expect(find.text('Reconnecting to 2 bridges...'), findsOneWidget);
    expect(bar, findsOneWidget);

    down.clear();
    await home.refresh(quiet: true);
    await tester.pump();
    expect(bar, findsNothing);
    home.dispose();
  });

  testWidgets('the bar takes the status bar inset, and the screen under it does not get it again', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 60);
    addTearDown(tester.view.reset);
    final store = MemoryHomeStore();
    await store.save(
      const HomeSnapshot(
        bridges: [BridgeAccount(id: 'a', name: 'Hall', host: '192.168.1.2', appKey: 'k')],
      ),
    );
    final home = HomeController(
      AppServices(
        central: SimulatedBleCentral(),
        bridgeClient: (host) =>
            HueBridgeClient(MockClient((_) async => throw http.ClientException('no route')), Uri.parse('http://$host')),
        store: store,
      ),
    );
    await home.load();
    await tester.pumpWidget(
      HomeScope(
        home: home,
        child: MaterialApp(
          builder: (context, child) => ReconnectBar(child: child!),
          home: Builder(builder: (context) => Text('top ${MediaQuery.paddingOf(context).top}')),
        ),
      ),
    );
    expect(find.text('top ${60 / tester.view.devicePixelRatio}'), findsOneWidget);
    await home.refresh(quiet: true);
    await tester.pump();
    expect(find.text('top 0.0'), findsOneWidget);
    home.dispose();
  });
}
