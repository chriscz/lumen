// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/emulator/multicast_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('lumen/multicast');
  final calls = <String>[];
  final printed = <String>[];
  late DebugPrintCallback savedPrint;

  TestDefaultBinaryMessenger messenger() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void answer(Future<Object?>? Function(MethodCall call) handler) =>
      messenger().setMockMethodCallHandler(channel, (call) {
        calls.add(call.method);
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

  test('on Android it takes and gives back the lock through the channel', () async {
    answer((_) async => null);
    final lock = PlatformMulticastLock(onAndroid: () => true);
    await lock.acquire();
    await lock.release();
    expect(calls, ['acquire', 'release']);
    expect(printed, isEmpty);
  });

  test('off Android it never touches the channel', () async {
    answer((_) async => null);
    await PlatformMulticastLock(onAndroid: () => false).acquire();
    // The test host is not Android, so the default check says the same.
    await const PlatformMulticastLock().acquire();
    await const PlatformMulticastLock().release();
    expect(calls, isEmpty);
  });

  test('a platform failure is logged and does not stop the emulator', () async {
    answer((_) async => throw PlatformException(code: 'denied', message: 'no Wi-Fi'));
    await PlatformMulticastLock(onAndroid: () => true).acquire();
    expect(calls, ['acquire']);
    expect(printed.single, startsWith('Multicast lock acquire failed: PlatformException(denied, no Wi-Fi'));
  });

  test('a build without the channel carries on quietly', () async {
    // No handler: the call fails with MissingPluginException.
    await PlatformMulticastLock(onAndroid: () => true).release();
    expect(printed, isEmpty);
  });

  test('NoMulticastLock does nothing and never fails', () async {
    answer((_) async => null);
    const lock = NoMulticastLock();
    await expectLater(lock.acquire(), completes);
    await expectLater(lock.release(), completes);
    expect(calls, isEmpty);
  });
}
