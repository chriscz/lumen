// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/log/app_logging.dart';
import 'package:lumen/log/logger.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// A Pixel 8 on Android 14, as device_info_plus reports it.
AndroidDeviceInfo pixel8() => AndroidDeviceInfo.setMockInitialValues(
  version: AndroidBuildVersion.setMockInitialValues(
    codename: 'REL',
    incremental: '1',
    previewSdkInt: 0,
    release: '14',
    sdkInt: 34,
  ),
  board: 'shiba',
  bootloader: '1',
  brand: 'google',
  device: 'shiba',
  display: 'AP1A',
  fingerprint: 'google/shiba',
  hardware: 'shiba',
  host: 'build',
  id: 'AP1A',
  manufacturer: 'Google',
  model: 'Pixel 8',
  product: 'shiba',
  name: 'Pixel 8',
  supported32BitAbis: const [],
  supported64BitAbis: const ['arm64-v8a'],
  supportedAbis: const ['arm64-v8a'],
  tags: 'release-keys',
  time: 0,
  type: 'user',
  isPhysicalDevice: true,
  freeDiskSize: 0,
  totalDiskSize: 0,
  systemFeatures: const [],
  isLowRamDevice: false,
  physicalRamSize: 8192,
  availableRamSize: 4096,
);

class _BrokenStatusCentral extends SimulatedBleCentral {
  @override
  Future<Map<String, String>> status() async => throw StateError('adapter gone');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('the run header lists what was collected, one item per line', () {
    final text = AppLogging.header({
      'App': '1.0.0+1',
      'Build': 'release',
      'Android': '14 (SDK 34)',
      'Device': 'Google Pixel 8',
      'Bluetooth': 'poweredOn',
      'Permissions': 'granted',
    });
    expect(text.split('\n').first, 'Lumen run started');
    expect(text, contains('App: 1.0.0+1'));
    expect(text, contains('Android: 14 (SDK 34)'));
    expect(text, contains('Permissions: granted'));
  });

  test('uncaught Flutter and platform errors are logged at error level with stack traces', () {
    final log = Logger.memory();
    final flutterBefore = FlutterError.onError;
    final platformBefore = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = flutterBefore;
      PlatformDispatcher.instance.onError = platformBefore;
    });
    AppLogging.captureErrors(log, presentFlutterErrors: false);

    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('in build'), stack: StackTrace.fromString('#0 build')),
    );
    expect(PlatformDispatcher.instance.onError!(StateError('async'), StackTrace.fromString('#0 tick')), isTrue);
    AppLogging.zoneError(log, StateError('zone'), StackTrace.fromString('#0 zone'));

    expect(log.entries.map((e) => e.level), everyElement(LogLevel.error));
    final text = log.entries.map((e) => e.message).join('\n');
    expect(text, contains('in build'));
    expect(text, contains('#0 build'));
    expect(text, contains('async'));
    expect(text, contains('#0 tick'));
    expect(text, contains('#0 zone'));
  });

  test('a Flutter error names its context and is still presented when asked', () {
    final log = Logger.memory();
    final flutterBefore = FlutterError.onError;
    final presentBefore = FlutterError.presentError;
    final platformBefore = PlatformDispatcher.instance.onError;
    final presented = <FlutterErrorDetails>[];
    FlutterError.presentError = presented.add;
    addTearDown(() {
      FlutterError.onError = flutterBefore;
      FlutterError.presentError = presentBefore;
      PlatformDispatcher.instance.onError = platformBefore;
    });
    AppLogging.captureErrors(log);

    final details = FlutterErrorDetails(exception: StateError('layout'), context: ErrorDescription('during layout'));
    FlutterError.onError!(details);
    expect(log.entries.single.message, startsWith('Flutter error during layout\nBad state: layout'));
    expect(presented, [details]);
  });

  group('open', () {
    late Directory support;

    setUp(() => support = Directory.systemTemp.createTempSync('lumen-support'));
    tearDown(() {
      messenger.setMockMethodCallHandler(pathProvider, null);
      support.deleteSync(recursive: true);
    });

    test('keeps the log in a logs folder of the app support directory', () async {
      messenger.setMockMethodCallHandler(
        pathProvider,
        (call) async => call.method == 'getApplicationSupportDirectory' ? support.path : null,
      );
      final log = await AppLogging.open();
      expect(log.directory?.path, '${support.path}/logs');
      log
        ..info(LogTag.app, 'kept between runs')
        ..flush();
      expect(File('${support.path}/logs/lumen-00001.log').readAsStringSync(), contains('kept between runs'));
    });

    test('without a support directory it logs to memory and says why', () async {
      messenger.setMockMethodCallHandler(pathProvider, (call) async => throw PlatformException(code: 'no-storage'));
      final printed = <String>[];
      final before = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      addTearDown(() => debugPrint = before);

      final log = await AppLogging.open();
      expect(log.directory, isNull);
      expect(printed.single, startsWith('no log directory, logging to memory:'));
      expect(printed.single, contains('no-storage'));
    });
  });

  group('logRunHeader', () {
    setUp(
      () => PackageInfo.setMockInitialValues(
        appName: 'Lumen',
        packageName: 'dev.lumen',
        version: '1.2.3',
        buildNumber: '45',
        buildSignature: '',
      ),
    );

    test('on Android it logs the app, build, Android version, device and Bluetooth state', () async {
      final log = Logger.memory();
      final central = SimulatedBleCentral(permissionGranted: false);
      await AppLogging.logRunHeader(
        log,
        central,
        android: true,
        deviceInfo: DeviceInfoPlugin.setMockInitialValues(androidDeviceInfo: pixel8()),
      );
      final entry = log.entries.single;
      expect(entry.level, LogLevel.info);
      expect(entry.tag, LogTag.app);
      expect(entry.message.split('\n'), [
        'Lumen run started',
        'App: 1.2.3+45',
        'Build: debug',
        'Android: 14 (SDK 34)',
        'Device: Google Pixel 8',
        'Bluetooth: poweredOn',
        'Permissions: not granted',
      ]);
      expect(central.permissionRequests, 0, reason: 'the header never prompts');
    });

    test('elsewhere, as on the machine running the tests, it logs the operating system instead', () async {
      final log = Logger.memory();
      // No android argument: the header asks the platform, which is not Android here.
      await AppLogging.logRunHeader(log, SimulatedBleCentral(available: false));
      final lines = log.entries.single.message.split('\n');
      expect(lines, contains('OS: ${Platform.operatingSystemVersion}'));
      expect(lines, contains('Bluetooth: poweredOff'));
      expect(lines.where((l) => l.startsWith('Android') || l.startsWith('Device')), isEmpty);
    });

    test('facts that cannot be read are logged as unknown, with the reason', () async {
      final log = Logger.memory();
      await AppLogging.logRunHeader(log, _BrokenStatusCentral(), android: true, deviceInfo: DeviceInfoPlugin());
      final lines = log.entries.single.message.split('\n');
      expect(lines, contains('App: 1.2.3+45'));
      expect(lines.singleWhere((l) => l.startsWith('Device: ')), startsWith('Device: unknown ('));
      expect(lines, contains('Bluetooth: unknown (Bad state: adapter gone)'));
    });
  });
}
