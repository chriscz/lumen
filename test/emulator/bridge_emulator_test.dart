// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/emulator/bridge_emulator.dart';
import 'package:lumen/emulator/bridge_server.dart';
import 'package:lumen/emulator/emulator_settings.dart';
import 'package:lumen/emulator/multicast_lock.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/sim/simulated_bridge_platform.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/emulator_store.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/transport/bridge/bridge_ports.dart';

class RecordingLock implements MulticastLock {
  final calls = <String>[];

  @override
  Future<void> acquire() async => calls.add('acquire');

  @override
  Future<void> release() async => calls.add('release');
}

void main() {
  late MemoryEmulatorStore store;
  late RecordingLock lock;
  late HomeController home;
  late DateTime now;

  BridgeEmulator build() => BridgeEmulator(home, clock: () => now);

  setUp(() async {
    now = DateTime.utc(2026, 10, 23, 12);
    store = MemoryEmulatorStore();
    lock = RecordingLock();
    final central = SimulatedBleCentral(scanDelay: Duration.zero)..addBulb(SimulatedHueBulb(id: 'aa', name: 'Desk'));
    home = HomeController(
      AppServices.simulated(central: central, store: MemoryHomeStore(), emulatorStore: store, multicast: lock),
    );
    await home.load();
    final found = await home.scanBluetooth().first;
    await home.addBluetoothLight(found);
  });

  tearDown(() => home.dispose());

  String pair(BridgeEmulator emulator, String devicetype) {
    emulator.pressLinkButton();
    final (_, json) = emulator.api.handle('POST', '/api', jsonEncode({'devicetype': devicetype}));
    return (((json as List).single as Map)['success'] as Map)['username'] as String;
  }

  test('a first load creates an identity and keeps it across restarts', () async {
    final first = build();
    await first.load();
    expect(first.loaded, isTrue);
    expect(first.enabled, isFalse);
    expect(first.running, isFalse);
    expect(store.json, isNotNull);
    final again = build();
    await again.load();
    expect(again.settings.mac, first.settings.mac);
    expect(again.settings.bridgeId, first.settings.bridgeId);
  });

  test('switching on starts the server, takes the multicast lock and is remembered', () async {
    final emulator = build();
    await emulator.load();
    var notified = 0;
    emulator.addListener(() => notified++);
    await emulator.setEnabled(true);
    expect(emulator.running, isTrue);
    expect(emulator.url, 'http://192.168.1.50:1818');
    expect(emulator.ssdp, isTrue);
    expect(lock.calls, ['acquire']);
    expect(notified, greaterThan(0));

    final restarted = build();
    await restarted.load();
    expect(restarted.running, isTrue, reason: 'starts at launch when it was on');

    await emulator.setEnabled(false);
    expect(emulator.running, isFalse);
    expect(emulator.url, isNull);
    expect(lock.calls.last, 'release');
    final off = build();
    await off.load();
    expect(off.running, isFalse);
    restarted.dispose();
    off.dispose();
    emulator.dispose();
  });

  test('paired apps and light ids survive a restart', () async {
    final emulator = build();
    await emulator.load();
    final key = pair(emulator, 'home-assistant#phone');
    final (_, lights) = emulator.api.handle('GET', '/api/$key/lights', '');
    expect((lights as Map).keys, ['1']);
    await pumpEventQueue();

    final restarted = build();
    await restarted.load();
    expect(restarted.pairedApps.single.devicetype, 'home-assistant#phone');
    final (_, again) = restarted.api.handle('GET', '/api/$key/lights', '');
    expect((again as Map).keys, ['1']);
    expect(restarted.settings.lightIds, emulator.settings.lightIds);
  });

  test('revoking an app forgets its key', () async {
    final emulator = build();
    await emulator.load();
    final key = pair(emulator, 'a#b');
    await emulator.revoke(key);
    expect(emulator.pairedApps, isEmpty);
    final (_, json) = emulator.api.handle('GET', '/api/$key/lights', '');
    expect(((json as List).single as Map)['error']['type'], 1);
    final restarted = build();
    await restarted.load();
    expect(restarted.pairedApps, isEmpty);
  });

  test('the link button opens a 30 second window and counts down', () async {
    final emulator = build();
    await emulator.load();
    expect(emulator.linkButtonRemaining, Duration.zero);
    emulator.pressLinkButton();
    expect(emulator.linkButtonRemaining, const Duration(seconds: 30));
    now = now.add(const Duration(seconds: 12));
    expect(emulator.linkButtonRemaining, const Duration(seconds: 18));
    now = now.add(const Duration(seconds: 20));
    expect(emulator.linkButtonRemaining, Duration.zero);
    emulator.dispose();
  });

  test('announce on Wi-Fi is on by default and older saved settings read as on', () async {
    final emulator = build();
    await emulator.load();
    expect(emulator.announce, isTrue);
    final json = jsonDecode(store.json!) as Map<String, Object?>;
    expect(json['announce'], isTrue);
    store.json = jsonEncode(json..remove('announce'));
    final older = build();
    await older.load();
    expect(older.announce, isTrue);
  });

  test('switching announce off is remembered, told to the server and shown', () async {
    final emulator = build();
    await emulator.load();
    expect(emulator.announcement, isNull, reason: 'nothing to say while the bridge is off');
    await emulator.setEnabled(true);
    expect(emulator.announcing, isTrue);
    expect(
      emulator.announcement,
      'Announcing as Lumen-${emulator.settings.bridgeId.substring(10)} on Wi-Fi via mDNS and SSDP',
    );

    var notified = 0;
    emulator.addListener(() => notified++);
    await emulator.setAnnounce(false);
    expect(notified, greaterThan(0));
    expect(emulator.announce, isFalse);
    expect(emulator.announcing, isFalse);
    expect(emulator.ssdp, isFalse);
    expect(emulator.mdns, isFalse);
    expect(emulator.running, isTrue, reason: 'the HTTP API stays up');
    expect(emulator.announcement, startsWith('Not announcing: Announce on Wi-Fi is off'));

    final restarted = build();
    await restarted.load();
    expect(restarted.announce, isFalse);
    expect(restarted.announcing, isFalse);
    restarted.dispose();
    await emulator.setAnnounce(true);
    expect(emulator.announcing, isTrue);
    emulator.dispose();
  });

  group('in the background', () {
    late SimulatedBridgeBackground background;
    late SimulatedSystemMdns nsd;
    late HomeController phone;

    setUp(() async {
      background = SimulatedBridgeBackground();
      nsd = SimulatedSystemMdns();
      phone = HomeController(
        AppServices.simulated(
          store: MemoryHomeStore(),
          emulatorStore: store,
          multicast: lock,
          background: background,
          nsd: nsd,
        ),
      );
      await phone.load();
    });

    tearDown(() => phone.dispose());

    Future<BridgeEmulator> started() async {
      final emulator = BridgeEmulator(phone, clock: () => now);
      addTearDown(emulator.dispose);
      await emulator.load();
      await emulator.setEnabled(true);
      return emulator;
    }

    Object? request(BridgeEmulator emulator, String key) => emulator.api.handle('GET', '/api/$key/lights', '').$2;

    test('the service runs with the bridge, names its address and active apps, and stops with it', () async {
      final emulator = await started();
      expect(emulator.backgroundSupported, isTrue);
      expect(emulator.background, isTrue, reason: 'on by default');
      expect(background.running, isTrue);
      expect(background.text, 'Listening on 192.168.1.50:1818, no apps active');
      expect(background.stayAwakeWhileCharging, isFalse);
      expect(background.calls, ['run', 'requestNotifications']);

      final key = pair(emulator, 'home-assistant#phone');
      expect(background.text, 'Listening on 192.168.1.50:1818, 1 app active');
      expect(emulator.activeApps, 1);
      final runs = background.calls.length;
      request(emulator, key);
      expect(background.calls, hasLength(runs), reason: 'the text did not change');

      now = now.add(const Duration(minutes: 6));
      emulator.tick();
      expect(emulator.activeApps, 0);
      expect(background.text, 'Listening on 192.168.1.50:1818, no apps active');
      request(emulator, key);
      expect(background.text, 'Listening on 192.168.1.50:1818, 1 app active');

      await emulator.setEnabled(false);
      expect(background.running, isFalse);
      expect(background.calls.last, 'stop');
    });

    test('a denied notification permission leaves the bridge and the service running', () async {
      background.notificationsGranted = false;
      final emulator = await started();
      expect(emulator.running, isTrue);
      expect(background.running, isTrue);
    });

    test('with the setting off no service runs; switching it on while running starts it and asks once', () async {
      final emulator = BridgeEmulator(phone, clock: () => now);
      addTearDown(emulator.dispose);
      await emulator.load();
      await emulator.setBackground(false);
      await emulator.setEnabled(true);
      expect(background.calls, isEmpty);
      await emulator.setBackground(true);
      expect(background.running, isTrue);
      expect(background.calls, ['run', 'requestNotifications']);
      await emulator.setBackground(false);
      expect(background.running, isFalse);
      expect((jsonDecode(store.json!) as Map)['background'], isFalse);
      await emulator.setBackground(false);
      expect(background.calls, ['run', 'requestNotifications', 'stop']);
    });

    test('the bridge starting at launch runs the service without asking for permission', () async {
      await started();
      final relaunched = BridgeEmulator(phone, clock: () => now);
      addTearDown(relaunched.dispose);
      background.calls.clear();
      await relaunched.load();
      expect(relaunched.running, isTrue);
      expect(background.calls, ['run']);
    });

    test('stay fully awake while charging goes to the service and is remembered', () async {
      final emulator = await started();
      expect(emulator.stayAwakeWhileCharging, isFalse);
      await emulator.setStayAwakeWhileCharging(true);
      expect(background.stayAwakeWhileCharging, isTrue);
      expect((jsonDecode(store.json!) as Map)['stayAwakeWhileCharging'], isTrue);
      await emulator.setStayAwakeWhileCharging(true);
      await emulator.setStayAwakeWhileCharging(false);
      expect(background.stayAwakeWhileCharging, isFalse);
    });

    test('the battery settings open through the service', () async {
      final emulator = await started();
      expect(await emulator.openBatterySettings(), isTrue);
      expect(background.calls.last, 'openBatterySettings');
    });

    test('a bridge that cannot listen runs no service', () async {
      final failing = HomeController(
        AppServices.simulated(
          store: MemoryHomeStore(),
          emulatorStore: MemoryEmulatorStore(),
          background: background,
          emulatorServer: (api, ports, _) => _NeverRunning(api, ports),
        ),
      );
      addTearDown(failing.dispose);
      await failing.load();
      final emulator = BridgeEmulator(failing, clock: () => now);
      addTearDown(emulator.dispose);
      await emulator.load();
      await emulator.setEnabled(true);
      expect(background.running, isFalse);
    });

    test('seen times are saved on the minute tick and when the bridge stops, not per request', () async {
      final emulator = await started();
      final key = pair(emulator, 'a#b');
      request(emulator, key);
      String? savedSeen() => ((jsonDecode(store.json!) as Map)['users'] as List).single['lastUsed'] as String?;
      final paired = savedSeen();

      now = now.add(const Duration(seconds: 20));
      request(emulator, key);
      await pumpEventQueue();
      expect(savedSeen(), paired);
      emulator.tick();
      await pumpEventQueue();
      expect(savedSeen(), now.toIso8601String());

      now = now.add(const Duration(seconds: 10));
      request(emulator, key);
      await emulator.setEnabled(false);
      expect(savedSeen(), now.toIso8601String());
    });

    test('the summary counts paired and recently active apps', () async {
      final emulator = await started();
      expect(emulator.appsSummary, isNull);
      final a = pair(emulator, 'a#b');
      expect(emulator.appsSummary, '1 app paired, 1 active in the last 5 minutes');
      now = now.add(const Duration(minutes: 3));
      pair(emulator, 'c#d');
      now = now.add(const Duration(minutes: 3));
      expect(emulator.appsSummary, '2 apps paired, 1 active in the last 5 minutes');
      now = now.add(const Duration(minutes: 10));
      expect(emulator.appsSummary, '2 apps paired, none active in the last 5 minutes');
      request(emulator, a);
      expect(emulator.activeApps, 1);
    });

    test('an app removed through the API disappears from Settings at once', () async {
      final emulator = await started();
      final a = pair(emulator, 'a#b');
      final b = pair(emulator, 'c#d');
      var notified = 0;
      emulator.addListener(() => notified++);
      emulator.api.handle('DELETE', '/api/$a/config/whitelist/$b', '');
      expect(notified, greaterThan(0));
      expect(emulator.pairedApps.map((p) => p.username), [a]);
      await emulator.revoke(a);
      await emulator.revoke(a);
      expect(emulator.pairedApps, isEmpty);
    });

    test('mDNS and SSDP switches are remembered and named in the status', () async {
      final emulator = await started();
      final name = 'Lumen-${emulator.settings.bridgeId.substring(10)}';
      expect(emulator.announcement, 'Announcing as $name on Wi-Fi via mDNS (Android) and SSDP');
      await emulator.setSsdpEnabled(false);
      expect(emulator.ssdp, isFalse);
      expect(emulator.announcement, 'Announcing as $name on Wi-Fi via mDNS (Android)');
      await emulator.setMdnsEnabled(false);
      expect(emulator.announcing, isFalse);
      expect(emulator.announcement, startsWith('Not announcing: mDNS and SSDP are off'));
      await emulator.setMdnsEnabled(false);
      await emulator.setSsdpEnabled(true);
      expect(emulator.announcement, 'Announcing as $name on Wi-Fi via SSDP');
      final json = jsonDecode(store.json!) as Map;
      expect([json['mdnsEnabled'], json['ssdpEnabled']], [false, true]);
      expect([emulator.mdnsEnabled, emulator.ssdpEnabled], [false, true]);
    });

    test('the mDNS implementation defaults to Android where it exists and can be switched', () async {
      final emulator = await started();
      expect(emulator.systemMdnsAvailable, isTrue);
      expect(emulator.mdnsImplementation, MdnsImplementation.system);
      expect(emulator.mdnsVia, MdnsImplementation.system);
      await emulator.setMdnsImplementation(MdnsImplementation.builtIn);
      expect(emulator.mdnsImplementation, MdnsImplementation.builtIn);
      expect(emulator.mdnsVia, MdnsImplementation.builtIn);
      expect(emulator.announcement, endsWith('via mDNS and SSDP'));
      expect((jsonDecode(store.json!) as Map)['mdnsImplementation'], 'builtIn');
      await emulator.setMdnsImplementation(MdnsImplementation.builtIn);
    });
  });

  test('without Android mDNS only the built-in one exists', () async {
    final emulator = build();
    await emulator.load();
    expect(emulator.systemMdnsAvailable, isFalse);
    expect(emulator.backgroundSupported, isFalse);
    expect(emulator.mdnsImplementation, MdnsImplementation.builtIn);
    expect(emulator.mdnsVia, isNull, reason: 'not running');
    expect(await emulator.openBatterySettings(), isFalse);
  });

  test('last seen reads as now, minutes, hours or a date', () {
    final at = DateTime.utc(2026, 10, 24, 12);
    PairedApp app(DateTime? seen) =>
        PairedApp(username: 'k', devicetype: 'd', created: DateTime.utc(2026), lastUsed: seen);
    expect(BridgeEmulator.lastSeen(app(null), at), 'Not seen yet');
    expect(BridgeEmulator.lastSeen(app(at.subtract(const Duration(minutes: 2))), at), 'Active now');
    expect(BridgeEmulator.lastSeen(app(at.subtract(const Duration(minutes: 12))), at), 'Last seen 12 min ago');
    expect(BridgeEmulator.lastSeen(app(at.subtract(const Duration(hours: 3))), at), 'Last seen 3 h ago');
    expect(BridgeEmulator.lastSeen(app(DateTime.utc(2026, 10, 20, 9)), at), 'Last seen 2026-10-20');
  });

  test('the status names only the enabled mechanisms and notes an Android mDNS failure', () {
    expect(
      BridgeEmulator.describe(name: 'L', announce: true, ssdp: true, mdns: false, mdnsOn: false),
      'Announcing as L on Wi-Fi via SSDP',
    );
    expect(
      BridgeEmulator.describe(name: 'L', announce: true, ssdp: false, mdns: true, ssdpOn: false),
      'Announcing as L on Wi-Fi via mDNS',
    );
    expect(
      BridgeEmulator.describe(name: 'L', announce: true, ssdp: false, mdns: false, ssdpOn: false, mdnsError: 'busy'),
      'Not announcing: busy (mDNS)',
    );
    expect(
      BridgeEmulator.describe(name: 'L', announce: true, ssdp: false, mdns: false, mdnsOn: false, ssdpOn: false),
      'Not announcing: mDNS and SSDP are off. Enter the address in the other app.',
    );
    expect(
      BridgeEmulator.describe(
        name: 'L',
        announce: true,
        ssdp: true,
        mdns: true,
        mdnsVia: MdnsImplementation.builtIn,
        systemMdnsError: 'NsdManager error 3',
      ),
      'Announcing as L on Wi-Fi via mDNS and SSDP; Android mDNS failed (NsdManager error 3), so the built-in one answers',
    );
    expect(
      BridgeEmulator.describe(name: 'L', announce: true, ssdp: false, mdns: false, mdnsOn: false),
      'Not announcing: unknown error (SSDP)',
    );
  });

  test('the status names what is busy when announcing is impossible', () {
    expect(
      BridgeEmulator.describe(
        name: 'Lumen-DDEEFF',
        announce: true,
        ssdp: true,
        mdns: false,
        mdnsError: 'the multicast port 5353 is busy',
      ),
      'Announcing as Lumen-DDEEFF on Wi-Fi via SSDP only; mDNS is unavailable: the multicast port 5353 is busy',
    );
    expect(
      BridgeEmulator.describe(name: 'Lumen-DDEEFF', announce: true, ssdp: false, mdns: true, ssdpError: 'boom'),
      'Announcing as Lumen-DDEEFF on Wi-Fi via mDNS only; SSDP is unavailable: boom',
    );
    expect(
      BridgeEmulator.describe(
        name: 'Lumen-DDEEFF',
        announce: true,
        ssdp: false,
        mdns: false,
        ssdpError: 'the multicast port 1900 is busy',
        mdnsError: 'the multicast port 5353 is busy',
      ),
      'Not announcing: the multicast port 5353 is busy (mDNS); the multicast port 1900 is busy (SSDP)',
    );
  });

  test('a fixed port in the settings is the only port tried', () async {
    final emulator = build();
    await emulator.load();
    expect(emulator.ports, [80, ...BridgePorts.lan]);
    emulator.settings.port = 8123;
    expect(emulator.ports, [8123]);
  });

  test('a server that cannot listen reports why, and the emulator passes it on', () async {
    final blocker = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(blocker.close);
    final failing = HomeController(
      AppServices.simulated(
        store: MemoryHomeStore(),
        emulatorStore: store,
        multicast: lock,
        emulatorServer: (api, ports, _) => BridgeServer(
          api,
          ports: ports,
          ssdpPort: 0,
          multicastGroup: null,
          mdnsPort: 0,
          mdnsGroup: null,
          addresses: () async => ['127.0.0.1'],
        ),
      ),
    );
    addTearDown(failing.dispose);
    await failing.load();
    final emulator = BridgeEmulator(failing, clock: () => now);
    addTearDown(emulator.dispose);
    await emulator.load();
    expect(emulator.error, isNull, reason: 'no server yet');
    emulator.settings.port = blocker.port;
    await emulator.setEnabled(true);
    expect(emulator.running, isFalse);
    expect(emulator.url, isNull);
    expect(emulator.error, startsWith('Could not listen on port ${blocker.port}: SocketException'));
  });

  test('the in-process server never reports an error', () async {
    final emulator = build();
    await emulator.load();
    await emulator.setEnabled(true);
    expect(emulator.running, isTrue);
    expect(emulator.error, isNull);
    emulator.dispose();
  });
}

/// A server that never gets going, as when every port is taken.
class _NeverRunning extends InProcessEmulatorServer {
  _NeverRunning(super.api, super.ports);

  @override
  Future<void> start() async {}

  @override
  String? get error => 'Could not listen';
}
