// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/errors.dart';
import 'package:lumen/domain/home.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/log/logger.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/ble/ble_central.dart';
import 'package:lumen/transport/ble/hue_ble_codec.dart';

/// A phone whose Bluetooth can fail in ways the plain simulation does not.
class _FlakyCentral extends SimulatedBleCentral {
  _FlakyCentral() : super(scanDelay: Duration.zero);

  /// Thrown by [ensureReady] while set.
  BleOperationException? notReady;

  /// Reading the capabilities characteristic drops the link while on.
  bool capabilitiesFail = false;

  @override
  Future<void> ensureReady({bool request = false}) async {
    if (notReady case final e?) throw e;
    return super.ensureReady(request: request);
  }

  @override
  Future<Uint8List> read(String deviceId, String service, String characteristic) async {
    if (capabilitiesFail && characteristic == HueGatt.capabilities) {
      readRequests.add((deviceId, characteristic));
      throw const BleOperationException(BleFailure.notConnected);
    }
    return super.read(deviceId, service, characteristic);
  }
}

void main() {
  late _FlakyCentral central;
  late SimulatedBridge bridge;
  late MemoryHomeStore store;
  late Logger log;
  late HomeController home;

  HomeController build() =>
      HomeController(AppServices.simulated(central: central, bridge: bridge, store: store, log: log));

  setUp(() async {
    central = _FlakyCentral();
    bridge = SimulatedBridge();
    store = MemoryHomeStore();
    log = Logger.memory();
    home = build();
    await home.load();
  });

  Future<Light> addBulb(String id, {String name = 'Desk'}) async {
    central.addBulb(SimulatedHueBulb(id: id, name: name));
    final found = await home.scanBluetooth().firstWhere((b) => b.deviceId == id);
    return home.addBluetoothLight(found);
  }

  Future<void> pairBridge() async {
    bridge.pressLinkButton();
    await home.pairBridge('192.168.1.2', interval: Duration.zero);
  }

  String bridgeId(String lightId) => HomeController.bridgeLightId(bridge.id, lightId);

  int capabilityReads() => central.readRequests.where((r) => r.$2 == HueGatt.capabilities).length;

  group('Bluetooth issues', () {
    test('with debug logging on, each issue is logged once and a repeat is logged as unchanged', () async {
      await addBulb('aa');
      await home.setDebugLogging(true);
      central.permissionGranted = false;

      await home.connectAll();
      final seq = home.bluetoothIssueSeq;
      expect(home.bluetoothIssue, isA<BluetoothPermissionDenied>());
      await home.connectAll();
      expect(home.bluetoothIssueSeq, seq, reason: 'the same issue is not shown again on its own');

      final notes = [
        for (final e in log.entries)
          if (e.level == LogLevel.debug && e.message.startsWith('bluetooth issue')) e.message,
      ];
      expect(notes, [
        'bluetooth issue (probe): BluetoothPermissionDenied',
        'bluetooth issue (probe): BluetoothPermissionDenied, unchanged',
      ]);
    });

    test('a probe that fails for another Bluetooth reason reports the error, not a lasting issue', () async {
      final light = await addBulb('aa');
      final errors = <LightError>[];
      home.errors.listen(errors.add);
      central.notReady = const BleOperationException(BleFailure.other, 'adapter busy', 'busy');

      await home.connectAll();
      await Future<void>.delayed(Duration.zero);
      expect(home.light(light.id)!.reachable, isFalse);
      expect(home.bluetoothIssue, isNull);
      expect(errors.single, isA<BluetoothError>().having((e) => e.code, 'code', 'busy'));
    });
  });

  test('capabilities that cannot be read on a probe are read again on the next one', () async {
    final light = await addBulb('aa');
    // A new launch: the features were read in the session that added it.
    home = build();
    await home.load();
    central.capabilitiesFail = true;
    final before = capabilityReads();

    await home.connectAll();
    expect(capabilityReads(), before + 1);
    expect(home.light(light.id)!.reachable, isTrue, reason: 'its state was read');
    expect(home.light(light.id)!.capabilities, isNotNull, reason: 'the stored capabilities are kept');

    central.capabilitiesFail = false;
    await home.connectAll();
    expect(capabilityReads(), before + 2, reason: 'a failed read does not count as read this session');
    await home.connectAll();
    expect(capabilityReads(), before + 2, reason: 'once read, not again until the next launch');
  });

  group('make discoverable', () {
    test('opens a Bluetooth bulb for bonding by another phone', () async {
      final light = await addBulb('aa');
      final bulb = central.bulbs['aa']!..pairingMode = false;
      await home.makeDiscoverable(light.id);
      expect(bulb.makeDiscoverableWrites, 1);
      expect(bulb.openForBonding, isTrue);
    });

    test('a refusal is logged and passed on', () async {
      final light = await addBulb('aa');
      central.bulbs['aa']!.refusesDiscoverable = true;
      await expectLater(home.makeDiscoverable(light.id), throwsA(isA<DiscoverableRefused>()));
      expect(
        log.entries.where((e) => e.level == LogLevel.warning).map((e) => e.message),
        contains(startsWith('make discoverable ble:aa failed: ')),
      );
    });

    test('does nothing for a bridge light or one that is not there', () async {
      bridge.addLight(SimulatedBridgeLight(name: 'Sofa'));
      await pairBridge();
      await home.makeDiscoverable(bridgeId('1'));
      await home.makeDiscoverable('ble:gone');
      expect(log.entries.map((e) => e.message), isNot(contains(startsWith('make discoverable'))));
    });
  });

  test('an effect for a light that is not there does nothing', () async {
    await addBulb('aa');
    final writes = central.bulbs['aa']!.writes.length;
    await home.setEffect('ble:gone', HueEffect.candle);
    expect(home.lights.single.state.effect, isNot(HueEffect.candle));
    expect(central.bulbs['aa']!.writes.length, writes);
  });

  test('renaming a light with Hue extra security keeps the app name and marks the light', () async {
    final light = await addBulb('aa');
    final errors = <LightError>[];
    home.errors.listen(errors.add);
    central.bulbs['aa']!.appSecurity = true;

    await home.rename(light.id, ' Reading lamp ');
    await Future<void>.delayed(Duration.zero);
    expect(home.light(light.id)!.name, 'Reading lamp');
    expect(central.bulbs['aa']!.name, 'Desk', reason: 'the bulb refused the name');
    expect(home.needsAppSecurity(light.id), isTrue);
    expect(errors.single, isA<NeedsAppSecurity>());
  });

  group('rooms', () {
    setUp(() {
      bridge
        ..addLight(SimulatedBridgeLight(name: 'Sofa'))
        ..addLight(SimulatedBridgeLight(name: 'Shelf', type: 'Color temperature light'))
        ..addLight(SimulatedBridgeLight(name: 'Hall', type: 'Dimmable light'));
    });

    test('updating a room renames it and moves lights in and out', () async {
      await pairBridge();
      final room = await home.createRoom('Lounge', [bridgeId('1'), bridgeId('2')]);

      await home.updateRoom(room.copyWith(name: 'Den'), [bridgeId('2'), bridgeId('3')]);
      expect(home.rooms.single.name, 'Den');
      expect(home.lightsIn(room.id).map((l) => l.name), unorderedEquals(['Shelf', 'Hall']));
      expect(home.light(bridgeId('1'))!.roomId, isNull);
      expect(home.unassigned.map((l) => l.name), ['Sofa']);

      final saved = await store.load();
      expect(saved.rooms.single.name, 'Den');
      expect(saved.lights.firstWhere((l) => l.name == 'Sofa').roomId, isNull);
    });

    test('a cluster is a colour light only with a colour member, else ambiance or white', () async {
      await pairBridge();
      final mixed = await home.createRoom('Mixed', [bridgeId('2'), bridgeId('3')], linked: true);
      expect(home.clusterLight(mixed).kind, LightKind.ambiance);
      await home.updateRoom(mixed, [bridgeId('3')]);
      expect(home.clusterLight(home.rooms.single).kind, LightKind.white);
      await home.updateRoom(home.rooms.single, [bridgeId('1'), bridgeId('3')]);
      expect(home.clusterLight(home.rooms.single).kind, LightKind.color);
    });

    test('linking a group makes it a cluster, and unlinking makes it a plain group again', () async {
      await pairBridge();
      final room = await home.createRoom('Lounge', [bridgeId('1'), bridgeId('2')]);
      expect(home.clusters, isEmpty);

      await home.setLinked(room.id, true);
      expect(home.clusters.single.id, room.id);
      expect((await store.load()).rooms.single.linked, isTrue);

      await home.setLinked(room.id, false);
      expect(home.clusters, isEmpty);
      expect((await store.load()).rooms.single.linked, isFalse);
    });

    test('a cluster offers every preset and the scenes with any of its lights', () async {
      await pairBridge();
      final room = await home.createRoom('Lounge', [bridgeId('1'), bridgeId('2')], linked: true);
      final withMember = await home.saveScene('Sofa only', [bridgeId('1')]);
      final without = await home.saveScene('Hall only', [bridgeId('3')]);

      final offered = home.profilesForCluster(room.id).map((p) => p.id);
      expect(offered, containsAll([...HomeController.starterProfiles().map((p) => p.id), withMember.id]));
      expect(offered, isNot(contains(without.id)));
    });
  });

  group('a scene on a cluster', () {
    const warm = LightState(on: true, brightness: 100, color: WhiteColor(400));
    const cool = LightState(on: true, brightness: 200, color: WhiteColor(200));

    setUp(() async {
      for (final name in ['A', 'B', 'Outside']) {
        bridge.addLight(SimulatedBridgeLight(name: name, type: 'Color temperature light'));
      }
      await pairBridge();
    });

    test('gives the cluster the look of the scene light that is in it', () async {
      final room = await home.createRoom('Pair', [bridgeId('1'), bridgeId('2')], linked: true);
      await home.sendAll([bridgeId('3')], cool.toCommand());
      await home.send(bridgeId('1'), warm.toCommand());
      final scene = await home.saveScene('Evening', [bridgeId('3'), bridgeId('1')]);

      await home.applyProfileToCluster(scene.id, room.id);
      expect(home.rooms.single.clusterState, warm);
      for (final id in ['1', '2']) {
        expect(bridge.lights[id]!.state.brightness, 100);
        expect(bridge.lights[id]!.state.color, const WhiteColor(400));
      }
    });

    test('without any of its lights, the cluster takes the first look of the scene', () async {
      final room = await home.createRoom('Pair', [bridgeId('1'), bridgeId('2')], linked: true);
      await home.send(bridgeId('3'), cool.toCommand());
      final scene = await home.saveScene('Elsewhere', [bridgeId('3')]);

      await home.applyProfileToCluster(scene.id, room.id);
      expect(home.rooms.single.clusterState, cool);
      expect(
        [
          for (final id in ['1', '2']) bridge.lights[id]!.state.brightness,
        ],
        [200, 200],
      );
      expect(home.rooms.single.detached, isEmpty);
    });

    test('an empty scene changes nothing', () async {
      final room = await home.createRoom('Pair', [bridgeId('1'), bridgeId('2')], linked: true);
      final scene = await home.saveScene('Nothing', const []);
      bridge.requests.clear();
      await home.applyProfileToCluster(scene.id, room.id);
      expect(home.rooms.single.clusterState, LightState.unknown);
      expect(bridge.requests, isEmpty);
    });
  });

  test('the theme choice is kept', () async {
    await home.setThemeChoice(ThemeChoice.light);
    expect(home.themeChoice, ThemeChoice.light);
    expect((await store.load()).theme, ThemeChoice.light);
  });
}
