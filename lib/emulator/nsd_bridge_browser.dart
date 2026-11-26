// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'nsd.dart';

/// Browses `_hue._tcp` with Android's NsdManager and resolves each service,
/// through the `lumen/nsd` channel. Finds nothing off Android.
class NsdBridgeBrowser {
  /// [onAndroid] says whether the app runs on Android; tests replace it.
  const NsdBridgeBrowser({this.onAndroid = _isAndroid});

  final bool Function() onAndroid;

  static bool _isAndroid() => !kIsWeb && Platform.isAndroid;

  /// The bridges that resolved within [window]; empty on any failure.
  Future<List<({String host, int port, String? bridgeId})>> browse(Duration window) async {
    if (!onAndroid()) return const [];
    final List<Object?> raw;
    try {
      raw =
          await PlatformNsd.channel.invokeListMethod<Object?>('browse', {
            'type': SystemMdns.hueType,
            'windowMs': window.inMilliseconds,
          }) ??
          const [];
    } on PlatformException catch (e) {
      debugPrint('NSD browse failed: $e');
      return const [];
    } on MissingPluginException {
      return const [];
    }
    return [
      for (final s in raw.whereType<Map<Object?, Object?>>())
        if ((s['host'], s['port']) case (final String host, final int port))
          (host: host, port: port, bridgeId: (s['txt'] as Map<Object?, Object?>?)?['bridgeid'] as String?),
    ];
  }
}
