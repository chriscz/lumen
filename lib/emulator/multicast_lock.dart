// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Lets the app receive multicast (SSDP searches) on Wi-Fi. Android drops
/// multicast packets unless an app holds a `WifiManager.MulticastLock`.
abstract interface class MulticastLock {
  Future<void> acquire();

  Future<void> release();
}

/// Does nothing: other platforms, tests and the simulated app.
class NoMulticastLock implements MulticastLock {
  const NoMulticastLock();

  @override
  Future<void> acquire() async {}

  @override
  Future<void> release() async {}
}

/// The lock held through the `lumen/multicast` channel in MainActivity.kt.
/// A no-op off Android.
class PlatformMulticastLock implements MulticastLock {
  /// [onAndroid] says whether the app runs on Android; tests replace it.
  const PlatformMulticastLock({this.onAndroid = _isAndroid});

  final bool Function() onAndroid;

  static const _channel = MethodChannel('lumen/multicast');

  static bool _isAndroid() => !kIsWeb && Platform.isAndroid;

  Future<void> _call(String method) async {
    if (!onAndroid()) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on PlatformException catch (e) {
      debugPrint('Multicast lock $method failed: $e');
    } on MissingPluginException {
      // An older build without the channel; SSDP may then miss searches.
    }
  }

  @override
  Future<void> acquire() => _call('acquire');

  @override
  Future<void> release() => _call('release');
}
