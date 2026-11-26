// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Keeps which plugins the user switched on or off, by plugin id. A plugin
/// with no entry follows its default.
abstract interface class PluginStore {
  Future<Map<String, bool>> load();

  Future<void> save(Map<String, bool> choices);
}

Map<String, bool> _decode(String raw) => {
  for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map).entries)
    if (value is bool) key as String: value,
};

/// Keeps the choices as JSON, so tests exercise the same encoding as the app.
class MemoryPluginStore implements PluginStore {
  String? json;

  @override
  Future<Map<String, bool>> load() async => json == null ? {} : _decode(json!);

  @override
  Future<void> save(Map<String, bool> choices) async => json = jsonEncode(choices);
}

class SharedPrefsPluginStore implements PluginStore {
  static const _key = 'plugins.v1';

  @override
  Future<Map<String, bool>> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return {};
    try {
      return _decode(raw);
    } on Object {
      return {};
    }
  }

  @override
  Future<void> save(Map<String, bool> choices) async =>
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode(choices));
}
