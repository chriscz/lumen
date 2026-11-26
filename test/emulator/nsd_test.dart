// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/emulator/nsd.dart';
import 'package:lumen/emulator/nsd_bridge_browser.dart';
import 'package:lumen/transport/bridge/lan_bridge_discovery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('lumen/nsd');
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

  group('registering', () {
    test('on Android it registers _hue._tcp with its port and TXT, and unregisters', () async {
      answer((_) async => null);
      final nsd = PlatformNsd(onAndroid: () => true);
      expect(nsd.available, isTrue);
      final error = await nsd.register(
        name: 'Lumen-DDEEFF',
        port: 1818,
        txt: {'bridgeid': 'aabbccfffeddeeff', 'modelid': 'BSB002'},
      );
      expect(error, isNull);
      await nsd.unregister();
      expect([for (final c in calls) c.method], ['register', 'unregister']);
      expect(calls.first.arguments, {
        'name': 'Lumen-DDEEFF',
        'type': '_hue._tcp',
        'port': 1818,
        'txt': {'bridgeid': 'aabbccfffeddeeff', 'modelid': 'BSB002'},
      });
    });

    test('a failed registration says why', () async {
      answer((call) async => throw PlatformException(code: 'failed', message: 'NsdManager error 3'));
      final error = await PlatformNsd(onAndroid: () => true).register(name: 'n', port: 1, txt: const {});
      expect(error, 'NsdManager error 3');
      answer((call) async => throw PlatformException(code: 'failed'));
      expect(await PlatformNsd(onAndroid: () => true).register(name: 'n', port: 1, txt: const {}), 'failed');
    });

    test('an unregister failure is logged', () async {
      answer((call) async => throw PlatformException(code: 'busy', message: 'nope'));
      await PlatformNsd(onAndroid: () => true).unregister();
      expect(printed.single, startsWith('NSD unregister failed: PlatformException(busy, nope'));
    });

    test('without the plugin registration fails with a reason', () async {
      final nsd = PlatformNsd(onAndroid: () => true);
      expect(await nsd.register(name: 'n', port: 1, txt: const {}), 'Android mDNS is missing from this build');
      await nsd.unregister();
    });

    test('off Android it is unavailable and never touches the channel', () async {
      answer((_) async => null);
      for (final nsd in [PlatformNsd(onAndroid: () => false), const PlatformNsd(), const NoSystemMdns()]) {
        expect(nsd.available, isFalse);
        expect(await nsd.register(name: 'n', port: 1, txt: const {}), 'Android mDNS is only on Android');
        await nsd.unregister();
      }
      expect(calls, isEmpty);
    });
  });

  group('browsing', () {
    test('on Android it browses _hue._tcp for the window and returns what resolved', () async {
      answer(
        (_) async => [
          {
            'host': '192.168.1.20',
            'port': 1818,
            'txt': {'bridgeid': 'aabbccfffeddeeff', 'modelid': 'BSB002'},
          },
          {'host': '192.168.1.30', 'port': 80, 'txt': <String, String>{}},
          {'host': '192.168.1.40', 'port': 443},
          'not a service',
          {'port': 80},
        ],
      );
      final MdnsBrowse browse = NsdBridgeBrowser(onAndroid: () => true).browse;
      final found = await browse(const Duration(seconds: 3));
      expect(found, [
        (host: '192.168.1.20', port: 1818, bridgeId: 'aabbccfffeddeeff'),
        (host: '192.168.1.30', port: 80, bridgeId: null),
        (host: '192.168.1.40', port: 443, bridgeId: null),
      ]);
      expect(calls.single.method, 'browse');
      expect(calls.single.arguments, {'type': '_hue._tcp', 'windowMs': 3000});
    });

    test('nothing found, a failure or a build without the plugin is an empty list', () async {
      final browser = NsdBridgeBrowser(onAndroid: () => true);
      expect(await browser.browse(const Duration(seconds: 1)), isEmpty, reason: 'no plugin');
      answer((_) async => null);
      expect(await browser.browse(const Duration(seconds: 1)), isEmpty);
      answer((_) async => throw PlatformException(code: 'failed', message: 'boom'));
      expect(await browser.browse(const Duration(seconds: 1)), isEmpty);
      expect(printed.single, startsWith('NSD browse failed: PlatformException(failed, boom'));
    });

    test('off Android it finds nothing and never touches the channel', () async {
      answer((_) async => const []);
      expect(await NsdBridgeBrowser(onAndroid: () => false).browse(const Duration(seconds: 1)), isEmpty);
      expect(await const NsdBridgeBrowser().browse(const Duration(seconds: 1)), isEmpty);
      expect(calls, isEmpty);
    });
  });
}
