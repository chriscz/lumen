// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../transport/ble/ble_central.dart';
import 'logger.dart';

/// Wires the app's log: where it lives, the header of each run, and the
/// uncaught errors it catches.
abstract final class AppLogging {
  /// The log in the app's support directory, kept between runs.
  static Future<Logger> open() async {
    try {
      final support = await getApplicationSupportDirectory();
      return Logger(directory: Directory('${support.path}/logs'));
    } catch (e) {
      debugPrint('no log directory, logging to memory: $e');
      return Logger();
    }
  }

  static String header(Map<String, String> facts) =>
      ['Lumen run started', for (final MapEntry(:key, :value) in facts.entries) '$key: $value'].join('\n');

  /// Logs the run header: app version, build mode, Android version, device,
  /// Bluetooth adapter state and permissions. Never prompts. Tests pass
  /// [deviceInfo] and [android] to stand in for the phone.
  static Future<void> logRunHeader(
    Logger log,
    BleCentral central, {
    DeviceInfoPlugin? deviceInfo,
    bool? android,
  }) async {
    final facts = <String, String>{};
    try {
      final app = await PackageInfo.fromPlatform();
      facts['App'] = '${app.version}+${app.buildNumber}';
    } catch (e) {
      facts['App'] = 'unknown ($e)';
    }
    facts['Build'] = kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug');
    try {
      if (android ?? Platform.isAndroid) {
        final info = await (deviceInfo ?? DeviceInfoPlugin()).androidInfo;
        facts['Android'] = '${info.version.release} (SDK ${info.version.sdkInt})';
        facts['Device'] = '${info.manufacturer} ${info.model}';
      } else {
        facts['OS'] = Platform.operatingSystemVersion;
      }
    } catch (e) {
      facts['Device'] = 'unknown ($e)';
    }
    try {
      facts.addAll(await central.status());
    } catch (e) {
      facts['Bluetooth'] = 'unknown ($e)';
    }
    log.info(LogTag.app, header(facts));
  }

  /// Sends uncaught errors to [log] at error level, with their stack traces.
  static void captureErrors(Logger log, {bool presentFlutterErrors = true}) {
    FlutterError.onError = (details) {
      log.error(
        LogTag.app,
        'Flutter error${details.context == null ? '' : ' ${details.context}'}',
        error: details.exception,
        stack: details.stack,
      );
      if (presentFlutterErrors) FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      log.error(LogTag.app, 'Uncaught error', error: error, stack: stack);
      return true;
    };
  }

  /// For runZonedGuarded around runApp.
  static void zoneError(Logger log, Object error, StackTrace stack) {
    log.error(LogTag.app, 'Uncaught error in zone', error: error, stack: stack);
    log.flush();
  }
}
