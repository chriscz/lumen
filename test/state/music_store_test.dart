// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/music/music_settings.dart';
import 'package:lumen/state/music_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('keeps music settings in shared preferences, and shrugs off nothing or garbage', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPrefsMusicStore();
    expect(await store.load(), isNull);
    const s = MusicSettings(style: MusicStyle.glow, follow: FollowMode.hits);
    await store.save(s);
    expect(await store.load(), s);
    SharedPreferences.setMockInitialValues({'music.v1': '{not json'});
    expect(await SharedPrefsMusicStore().load(), isNull);
  });
}
