// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/emulator/bridge_background.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('lumen/bridge_service');
  final calls = <MethodCall>[];
  final printed = <String>[];
  late DebugPrintCallback savedPrint;

  TestDefaultBinaryMessenger messenger() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void answer(Future<Object?>? Function(MethodCall call) handler) =>
      messenger().setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        return handler(call);
      });

  setUp(() {
    calls.clear();
    printed.clear();
    savedPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add('$message');
  });

  tearDown(() {
    debugPrint = savedPrint;
    messenger().setMockMethodCallHandler(channel, null);
  });

  test('on Android it runs, updates and stops the service through the channel', () async {
    answer((call) async => call.method == 'requestNotifications' || call.method == 'openBatterySettings');
    final service = PlatformBridgeBackground(onAndroid: () => true);
    expect(service.supported, isTrue);
    await service.run(text: 'Listening on 192.168.1.20:1818, no apps active', stayAwakeWhileCharging: true);
    await service.stop();
    expect(await service.requestNotifications(), isTrue);
    expect(await service.openBatterySettings(), isTrue);
    expect([for (final c in calls) c.method], ['run', 'stop', 'requestNotifications', 'openBatterySettings']);
    expect(calls.first.arguments, {
      'title': 'Lumen bridge running',
      'text': 'Listening on 192.168.1.20:1818, no apps active',
      'stayAwakeWhileCharging': true,
    });
    expect(printed, isEmpty);
  });

  test('off Android it is unsupported and never touches the channel', () async {
    answer((_) async => true);
    for (final service in [PlatformBridgeBackground(onAndroid: () => false), const PlatformBridgeBackground()]) {
      expect(service.supported, isFalse);
      await service.run(text: 't', stayAwakeWhileCharging: false);
      await service.stop();
      expect(await service.requestNotifications(), isFalse);
      expect(await service.openBatterySettings(), isFalse);
    }
    expect(calls, isEmpty);
  });

  test('a platform failure is logged and the bridge carries on', () async {
    answer((_) async => throw PlatformException(code: 'denied', message: 'no service'));
    final service = PlatformBridgeBackground(onAndroid: () => true);
    await service.run(text: 't', stayAwakeWhileCharging: false);
    expect(await service.requestNotifications(), isFalse);
    expect(printed.first, startsWith('Bridge service run failed: PlatformException(denied, no service'));
  });

  test('a build without the plugin carries on quietly', () async {
    final service = PlatformBridgeBackground(onAndroid: () => true);
    await service.stop();
    expect(await service.openBatterySettings(), isFalse);
    expect(printed, isEmpty);
  });

  test('NoBridgeBackground does nothing and says it is unsupported', () async {
    answer((_) async => true);
    const service = NoBridgeBackground();
    expect(service.supported, isFalse);
    await service.run(text: 't', stayAwakeWhileCharging: true);
    await service.stop();
    expect(await service.requestNotifications(), isFalse);
    expect(await service.openBatterySettings(), isFalse);
    expect(calls, isEmpty);
  });

  test('the notification text names the address and the active apps', () {
    expect(
      BridgeBackground.describe(url: 'http://192.168.1.20:1818', active: 0),
      'Listening on 192.168.1.20:1818, no apps active',
    );
    expect(
      BridgeBackground.describe(url: 'http://192.168.1.20:1818', active: 1),
      'Listening on 192.168.1.20:1818, 1 app active',
    );
    expect(
      BridgeBackground.describe(url: 'http://192.168.1.20:2020', active: 2),
      'Listening on 192.168.1.20:2020, 2 apps active',
    );
    expect(BridgeBackground.describe(url: null, active: 0), 'Starting');
  });
}
