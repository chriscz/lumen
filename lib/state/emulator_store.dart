// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../emulator/emulator_settings.dart';

/// Keeps the emulated bridge's settings, so paired clients survive restarts.
abstract interface class EmulatorStore {
  /// Null on first launch.
  Future<EmulatorSettings?> load();

  Future<void> save(EmulatorSettings settings);
}

/// Keeps the settings as JSON, so tests exercise the same encoding as the app.
class MemoryEmulatorStore implements EmulatorStore {
  String? json;

  @override
  Future<EmulatorSettings?> load() async =>
      json == null ? null : EmulatorSettings.fromJson(jsonDecode(json!) as Map<String, Object?>);

  @override
  Future<void> save(EmulatorSettings settings) async => json = jsonEncode(settings.toJson());
}

class SharedPrefsEmulatorStore implements EmulatorStore {
  static const _key = 'emulator.v1';

  @override
  Future<EmulatorSettings?> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return null;
    try {
      return EmulatorSettings.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> save(EmulatorSettings settings) async =>
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode(settings.toJson()));
}
