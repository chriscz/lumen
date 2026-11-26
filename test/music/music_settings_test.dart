// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/music/music_settings.dart';
import 'package:lumen/state/music_store.dart';

void main() {
  test('starts on the microphone, pulsing all lights in party colours', () {
    const s = MusicSettings();
    expect(s.source, AudioSource.microphone);
    expect(s.style, MusicStyle.pulse);
    expect(s.palette, MusicPalette.party);
    expect(s.roomId, isNull);
    expect(s.strength, 0.7);
    expect(s.timing, Duration.zero);
  });

  test('round trips through JSON', () {
    const s = MusicSettings(
      source: AudioSource.capture,
      style: MusicStyle.glow,
      palette: MusicPalette.cool,
      roomId: 'room-1',
      strength: 0.3,
      timing: Duration(milliseconds: -120),
    );
    final back = MusicSettings.fromJson(s.toJson());
    expect(back, s);
  });

  test('unknown or missing values fall back to the defaults, out of range ones are clamped', () {
    final s = MusicSettings.fromJson({'source': 'radio', 'style': 7, 'strength': 4.0, 'timingMs': -9000});
    expect(s.source, AudioSource.microphone);
    expect(s.style, MusicStyle.pulse);
    expect(s.strength, 1.0);
    expect(s.timing, MusicSettings.minTiming);
  });

  test('copyWith changes one thing and can clear the room', () {
    const s = MusicSettings(roomId: 'r');
    expect(s.copyWith(style: MusicStyle.colours).roomId, 'r');
    expect(s.copyWith(clearRoom: true).roomId, isNull);
  });

  test('the memory store keeps settings as JSON', () async {
    final store = MemoryMusicStore();
    expect(await store.load(), isNull);
    await store.save(const MusicSettings(style: MusicStyle.colours));
    expect(store.json, contains('colours'));
    expect((await store.load())!.style, MusicStyle.colours);
  });

  test('the tracking log is off by default, round trips and is changed by copyWith', () {
    expect(const MusicSettings().trackingLog, isFalse);
    final on = const MusicSettings().copyWith(trackingLog: true);
    expect(on.trackingLog, isTrue);
    expect(MusicSettings.fromJson(on.toJson()), on);
    expect(MusicSettings.fromJson(const {}).trackingLog, isFalse);
    expect(on == const MusicSettings(), isFalse);
  });

  test('follows in Auto with middle sensitivity and steadiness by default; all three round trip and clamp', () {
    const d = MusicSettings();
    expect(d.follow, FollowMode.auto);
    expect(d.sensitivity, 0.5);
    expect(d.steadiness, 0.5);
    final s = d.copyWith(follow: FollowMode.hits, sensitivity: 0.8, steadiness: 0.2);
    expect(MusicSettings.fromJson(s.toJson()), s);
    expect(s == d, isFalse);
    final wild = MusicSettings.fromJson({'follow': 'dance', 'sensitivity': 3, 'steadiness': -1});
    expect(wild.follow, FollowMode.auto);
    expect(wild.sensitivity, 1.0);
    expect(wild.steadiness, 0.0);
    expect(d.copyWith(sensitivity: 9).sensitivity, 1.0);
  });

  test('equal settings hash alike and say what they are', () {
    const s = MusicSettings();
    expect(s.hashCode, const MusicSettings().hashCode);
    expect(s.toString(), allOf(contains('microphone'), contains('follow: auto'), contains('sensitivity: 0.5')));
  });

  test('picked lights: none by default, round trip, and picking a room or all clears them', () {
    expect(const MusicSettings().lightIds, isEmpty);
    final s = const MusicSettings().copyWith(lightIds: ['ble:aa', 'ble:bb']);
    expect(MusicSettings.fromJson(s.toJson()), s);
    expect(s == const MusicSettings(), isFalse);
    expect(s.copyWith(roomId: 'r1').lightIds, isEmpty, reason: 'a room replaces the picked lights');
    expect(s.copyWith(clearRoom: true).lightIds, isEmpty, reason: 'all lights replaces them too');
    expect(MusicSettings.fromJson({'lightIds': 'nope'}).lightIds, isEmpty);
    expect(MusicSettings.fromJson({'lightIds': ['a', 3]}).lightIds, ['a']);
  });
}
