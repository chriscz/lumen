// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the emulated bridge listening while the app is in the background:
/// an Android foreground service with an ongoing notification, and
/// optionally a CPU and Wi-Fi wake lock while the phone charges.
abstract interface class BridgeBackground {
  /// The notification's title.
  static const title = 'Lumen bridge running';

  /// Whether the platform has such a service, and so the settings for it.
  bool get supported;

  /// Starts the service, or updates its notification [text] and wake lock
  /// choice when it already runs.
  Future<void> run({required String text, required bool stayAwakeWhileCharging});

  Future<void> stop();

  /// Asks for the notification permission (Android 13 and later). The
  /// service runs either way; false when it was not granted.
  Future<bool> requestNotifications();

  /// Opens Android's battery optimisation list, so the user can set the app
  /// to Unrestricted. False when it could not be opened.
  Future<bool> openBatterySettings();

  /// The notification text, such as `Listening on 192.168.1.20:1818, 2 apps
  /// active`, from the bridge's [url] and the number of [active] apps.
  static String describe({required String? url, required int active}) {
    if (url == null) return 'Starting';
    final apps = switch (active) {
      0 => 'no apps active',
      1 => '1 app active',
      _ => '$active apps active',
    };
    return 'Listening on ${Uri.parse(url).authority}, $apps';
  }
}

/// No background service: other platforms, tests and the simulated app.
class NoBridgeBackground implements BridgeBackground {
  const NoBridgeBackground();

  @override
  bool get supported => false;

  @override
  Future<void> run({required String text, required bool stayAwakeWhileCharging}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<bool> requestNotifications() async => false;

  @override
  Future<bool> openBatterySettings() async => false;
}

/// The foreground service of packages/lumen_bridge_service, through the
/// `lumen/bridge_service` channel. Does nothing off Android.
class PlatformBridgeBackground implements BridgeBackground {
  /// [onAndroid] says whether the app runs on Android; tests replace it.
  const PlatformBridgeBackground({this.onAndroid = _isAndroid});

  final bool Function() onAndroid;

  static const _channel = MethodChannel('lumen/bridge_service');

  static bool _isAndroid() => !kIsWeb && Platform.isAndroid;

  @override
  bool get supported => onAndroid();

  Future<bool> _call(String method, [Map<String, Object?>? arguments]) async {
    if (!onAndroid()) return false;
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on PlatformException catch (e) {
      debugPrint('Bridge service $method failed: $e');
    } on MissingPluginException {
      // A build without the plugin: the bridge runs while the app is open.
    }
    return false;
  }

  @override
  Future<void> run({required String text, required bool stayAwakeWhileCharging}) =>
      _call('run', {'title': BridgeBackground.title, 'text': text, 'stayAwakeWhileCharging': stayAwakeWhileCharging});

  @override
  Future<void> stop() => _call('stop');

  @override
  Future<bool> requestNotifications() => _call('requestNotifications');

  @override
  Future<bool> openBatterySettings() => _call('openBatterySettings');
}
