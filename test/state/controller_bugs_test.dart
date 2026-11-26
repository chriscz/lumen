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

void main() {
  late SimulatedBleCentral central;
  late SimulatedBridge bridge;
  late MemoryHomeStore store;
  late HomeController home;
  final deadHosts = <String>{};
  final garbageHosts = <String>{};

  HomeController build() {
    final sim = bridge.client();
    final dead = MockClient((_) async => throw http.ClientException('no route'));
    final garbage = MockClient((_) async => http.Response('{"not": "a list"}', 200));
    return HomeController(
      AppServices(
        central: central,
        bridgeClient: (host) => HueBridgeClient(
          _Switch(() => deadHosts.contains(host) ? dead : (garbageHosts.contains(host) ? garbage : sim)),
          Uri.parse('http://$host'),
        ),
        store: store,
      ),
    );
  }

  setUp(() async {
    deadHosts.clear();
    garbageHosts.clear();
    central = SimulatedBleCentral(scanDelay: Duration.zero, latency: const Duration(milliseconds: 5));
    bridge = SimulatedBridge(latency: const Duration(milliseconds: 20));
    for (var i = 1; i <= 3; i++) {
      bridge.addLight(SimulatedBridgeLight(name: 'B$i'));
    }
    bridge.addGroup('Lounge', ['1', '2', '3']);
    store = MemoryHomeStore();
    home = build();
    await home.load();
  });

  Future<String> loungeId() async {
    bridge.pressLinkButton();
    await home.pairBridge('old');
    return home.rooms.single.id;
  }

  test('after re-pairing on a new address, room commands go to the new address', () async {
    final room = await loungeId();
    await home.setRoomPower(room, true);
    deadHosts.add('old');
    bridge.pressLinkButton();
    await home.pairBridge('new');
    await home.setRoomPower(room, false);
    expect(bridge.lights.values.every((l) => l.state.on == false), isTrue);
    expect(home.lightsIn(room).every((l) => l.reachable), isTrue);
  });

  test('a light switched while its room command is queued ends as the user last asked', () async {
    final room = await loungeId();
    final x = home.lightsIn(room).first.id;
    final off = home.setRoomPower(room, false); // in flight
    final on = home.setRoomPower(room, true); // queued
    final lampOff = home.setPower(x, false); // last intent for x
    await Future.wait([off, on, lampOff]);
    expect(home.light(x)!.isOn, isFalse);
    expect(bridge.lights['1']!.state.on, isFalse, reason: 'the bulb matches what the UI shows');
    expect(bridge.lights['2']!.state.on, isTrue);
  });

  test('a failed room command does not undo a newer single-light change', () async {
    final room = await loungeId();
    final x = home.lightsIn(room).first.id;
    await home.setRoomPower(room, false);
    bridge.failGroups = true;
    final roomOn = home.setRoomPower(room, true);
    final lamp = home.setBrightness(x, 50);
    await Future.wait([roomOn, lamp]);
    expect(bridge.lights['1']!.state.brightness, 50);
    expect(home.light(x)!.state.brightness, 50);
  });

  test('an unexpected answer does not jam the light: later commands still go out', () async {
    await loungeId();
    final id = home.lights.first.id;
    garbageHosts.add('old');
    final errors = <LightError>[];
    home.errors.listen(errors.add);
    await home.setPower(id, true).timeout(const Duration(seconds: 2));
    expect(errors, isNotEmpty);
    garbageHosts.clear();
    await home.setPower(id, true).timeout(const Duration(seconds: 2));
    expect(bridge.lights['1']!.state.on, isTrue);
  });

  test('connectAll refreshes bridge lights without waiting for Bluetooth probes', () async {
    await loungeId();
    central = SimulatedBleCentral(scanDelay: Duration.zero, latency: const Duration(milliseconds: 300));
    final again = build();
    await again.load();
    final probing = again.connectAll();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(again.lights.where((l) => l.transport == Transport.bridge).every((l) => l.reachable), isTrue);
    await probing;
  });

  test('concurrent connectAll calls share one run', () async {
    await loungeId();
    final a = home.connectAll();
    final b = home.connectAll();
    expect(identical(a, b), isTrue);
    await a;
  });

  test('Bluetooth turned off is reported once at launch, as the Bluetooth issue', () async {
    central.addBulb(SimulatedHueBulb(id: 'aa'));
    final found = await home.scanBluetooth().first;
    await home.addBluetoothLight(found);
    central.available = false;
    final errors = <LightError>[];
    home.errors.listen(errors.add);
    var shown = 0;
    home.addListener(() => shown = home.bluetoothIssueSeq);
    await home.connectAll();
    await home.connectAll();
    await pumpEventQueue();
    expect(home.bluetoothIssue, isA<BluetoothUnavailable>());
    expect(shown, 1, reason: 'the second probe finds the same issue and does not show it again');
    expect(errors, isEmpty, reason: 'the issue has its own snack bar with Retry');
    expect(home.lights.single.reachable, isFalse);
  });

  test('undo after removing a light puts it back into its scenes', () async {
    await loungeId();
    final id = home.lights.first.id;
    final scene = await home.saveScene('Evening', home.lights.map((l) => l.id));
    final removed = home.light(id)!;
    await home.remove(id);
    await home.restore(removed);
    expect(home.profiles.firstWhere((p) => p.id == scene.id).states.keys, contains(id));
  });

  test('forgetting a bridge clears its groups', () async {
    final room = await loungeId();
    await home.forgetBridge(home.bridges.single.id);
    bridge.requests.clear();
    await home.setRoomPower(room, true);
    expect(bridge.requests, isEmpty);
  });
}

/// Delegates to whichever client [pick] returns at call time.
class _Switch extends http.BaseClient {
  _Switch(this.pick);

  final http.Client Function() pick;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => pick().send(request);
}
