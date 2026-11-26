// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/home.dart';

abstract interface class HomeStore {
  Future<HomeSnapshot> load();

  Future<void> save(HomeSnapshot snapshot);
}

/// Keeps the snapshot as JSON, so tests exercise the same encoding as the app.
class MemoryHomeStore implements HomeStore {
  String? json;

  @override
  Future<HomeSnapshot> load() async =>
      json == null ? HomeSnapshot.empty : HomeSnapshot.fromJson(jsonDecode(json!) as Map<String, Object?>);

  @override
  Future<void> save(HomeSnapshot snapshot) async => json = jsonEncode(snapshot.toJson());
}

class SharedPrefsHomeStore implements HomeStore {
  static const _key = 'home.v1';

  @override
  Future<HomeSnapshot> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return HomeSnapshot.empty;
    // A snapshot that is not JSON, or JSON of the wrong shape (a type error
    // in a cast), loads as an empty home rather than stopping the app.
    try {
      return HomeSnapshot.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } on Object {
      return const HomeSnapshot();
    }
  }

  @override
  Future<void> save(HomeSnapshot snapshot) async =>
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode(snapshot.toJson()));
}
