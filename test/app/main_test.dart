// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/app.dart';
import 'package:lumen/emulator/bridge_background.dart';
import 'package:lumen/emulator/multicast_lock.dart';
import 'package:lumen/emulator/nsd.dart';
import 'package:lumen/log/logger.dart';
import 'package:lumen/main.dart';
import 'package:lumen/music/platform_audio_input.dart';
import 'package:lumen/sim/simulated_audio.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/emulator_store.dart';
import 'package:lumen/state/home_store.dart';
import 'package:lumen/state/music_store.dart';
import 'package:lumen/state/plugin_store.dart';
import 'package:lumen/transport/ble/universal_ble_central.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Logger log;

  setUp(() {
    log = Logger.memory();
    final flutterBefore = FlutterError.onError;
    final platformBefore = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = flutterBefore;
      PlatformDispatcher.instance.onError = platformBefore;
    });
  });

  /// Runs [bootstrap] and returns the app it would run.
  Future<HueApp> start({required bool demo, AppServices Function(Logger log)? services}) {
    final ran = Completer<HueApp>();
    bootstrap(demo: demo, openLog: () async => log, services: services, run: (app) => ran.complete(app as HueApp));
    return ran.future;
  }

  Future<void> logged(bool Function(LogEntry e) test) async {
    for (var i = 0; i < 100 && !log.entries.any(test); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(log.entries.any(test), isTrue, reason: 'expected log entry');
  }

  test('runs the app on real Bluetooth and bridges, with the home kept on the phone', () async {
    final app = await start(demo: false);
    final services = app.home.services;
    expect(services.demo, isFalse);
    expect(services.central, isA<UniversalBleCentral>());
    expect(services.store, isA<SharedPrefsHomeStore>());
    expect(services.emulatorStore, isA<SharedPrefsEmulatorStore>());
    expect(services.multicast, isA<PlatformMulticastLock>());
    expect(services.background, isA<PlatformBridgeBackground>());
    expect(services.nsd, isA<PlatformNsd>());
    expect(services.audio, isA<PlatformAudioInput>());
    expect(services.musicStore, isA<SharedPrefsMusicStore>());
    expect(services.pluginStore, isA<SharedPrefsPluginStore>());
    expect(services.log, same(log));
    expect(services.bridgeClient('192.168.1.2').base, Uri.parse('https://192.168.1.2'));
    expect(app.home.loaded, isFalse, reason: 'the app loads the home itself');
    await logged((e) => e.message.startsWith('Lumen run started'));
  });

  test('in demo mode runs the app on the simulated home, kept on the phone', () async {
    final app = await start(demo: true);
    final services = app.home.services;
    expect(services.demo, isTrue);
    expect((services.central as SimulatedBleCentral).bulbs, hasLength(3));
    expect(services.store, isA<SharedPrefsHomeStore>());
    expect(services.emulatorStore, isA<SharedPrefsEmulatorStore>());
    expect(services.audio, isA<SimulatedAudioInput>());
    expect(services.musicStore, isA<SharedPrefsMusicStore>());
    expect(services.pluginStore, isA<SharedPrefsPluginStore>());
    expect(services.log, same(log));
    await logged((e) => e.message.startsWith('Lumen run started') && e.message.contains('Bluetooth: poweredOn'));
  });

  test('uses the services it is given, and sends uncaught Flutter errors to the log', () async {
    final given = AppServices.simulated(log: log);
    final app = await start(demo: true, services: (_) => given);
    expect(app.home.services, same(given));

    FlutterError.presentError = (_) {};
    addTearDown(() => FlutterError.presentError = FlutterError.dumpErrorToConsole);
    FlutterError.onError!(FlutterErrorDetails(exception: StateError('in build')));
    expect(log.entries.last.level, LogLevel.error);
    expect(log.entries.last.message, contains('in build'));
  });

  test('an error while starting is logged once the log is open', () async {
    bootstrap(demo: true, openLog: () async => log, services: (_) => throw StateError('no services'));
    await logged(
      (e) => e.level == LogLevel.error && e.message.startsWith('Uncaught error in zone\nBad state: no services'),
    );
  });

  test('an error before the log is open is printed', () async {
    final printed = Completer<String>();
    final before = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.complete(message);
    addTearDown(() => debugPrint = before);

    bootstrap(demo: true, openLog: () async => throw StateError('no storage'), run: (_) => fail('must not run'));
    final message = await printed.future;
    expect(message, startsWith('Uncaught error before the log opened: Bad state: no storage'));
  });

  test('local discovery offers Android mDNS only on Android', () {
    expect(lanDiscovery(log, android: true).hasAndroidMdns, isTrue);
    expect(lanDiscovery(log, android: false).hasAndroidMdns, isFalse);
  });
}
