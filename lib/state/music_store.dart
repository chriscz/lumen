// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../music/music_settings.dart';

/// Keeps the music sync settings between runs.
abstract interface class MusicStore {
  /// Null on first launch.
  Future<MusicSettings?> load();

  Future<void> save(MusicSettings settings);
}

/// Keeps the settings as JSON, so tests exercise the same encoding as the app.
class MemoryMusicStore implements MusicStore {
  String? json;

  @override
  Future<MusicSettings?> load() async =>
      json == null ? null : MusicSettings.fromJson(jsonDecode(json!) as Map<String, Object?>);

  @override
  Future<void> save(MusicSettings settings) async => json = jsonEncode(settings.toJson());
}

class SharedPrefsMusicStore implements MusicStore {
  static const _key = 'music.v1';

  @override
  Future<MusicSettings?> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return null;
    try {
      return MusicSettings.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> save(MusicSettings settings) async =>
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode(settings.toJson()));
}
