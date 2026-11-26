// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The platform's own mDNS responder: Android's NsdManager, which owns port
/// 5353 on the phone and so is heard more reliably than a second responder
/// sharing that port.
abstract interface class SystemMdns {
  /// The DNS-SD service type of a Hue bridge.
  static const hueType = '_hue._tcp';

  /// Whether this platform has a system responder.
  bool get available;

  /// Registers a `_hue._tcp` service called [name] on [port] with [txt].
  /// Null on success, else why it failed.
  Future<String?> register({required String name, required int port, required Map<String, String> txt});

  Future<void> unregister();
}

/// No system responder: other platforms and tests.
class NoSystemMdns implements SystemMdns {
  const NoSystemMdns();

  @override
  bool get available => false;

  @override
  Future<String?> register({required String name, required int port, required Map<String, String> txt}) async =>
      PlatformNsd.notAndroid;

  @override
  Future<void> unregister() async {}
}

/// Android's NsdManager through the `lumen/nsd` channel of
/// packages/lumen_bridge_service. Unavailable off Android.
class PlatformNsd implements SystemMdns {
  /// [onAndroid] says whether the app runs on Android; tests replace it.
  const PlatformNsd({this.onAndroid = _isAndroid});

  final bool Function() onAndroid;

  static const channel = MethodChannel('lumen/nsd');
  static const notAndroid = 'Android mDNS is only on Android';
  static const missing = 'Android mDNS is missing from this build';

  static bool _isAndroid() => !kIsWeb && Platform.isAndroid;

  @override
  bool get available => onAndroid();

  @override
  Future<String?> register({required String name, required int port, required Map<String, String> txt}) async {
    if (!onAndroid()) return notAndroid;
    try {
      await channel.invokeMethod<void>('register', {
        'name': name,
        'type': SystemMdns.hueType,
        'port': port,
        'txt': txt,
      });
      return null;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } on MissingPluginException {
      return missing;
    }
  }

  @override
  Future<void> unregister() async {
    if (!onAndroid()) return;
    try {
      await channel.invokeMethod<void>('unregister');
    } on PlatformException catch (e) {
      debugPrint('NSD unregister failed: $e');
    } on MissingPluginException {
      // Nothing was registered without the plugin.
    }
  }
}
