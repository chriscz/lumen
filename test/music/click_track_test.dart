// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/sim/click_track.dart';

void main() {
  double energy(List<double> s) => s.fold(0.0, (a, v) => a + v * v);

  test('a click track is loud on the beat and quiet between beats', () {
    final track = ClickTrack(bpm: 120, sampleRate: 8000);
    final samples = track.take(8000);
    // Beats at 0 and 0.5 s: the first 40 ms of a beat outweigh 40 ms halfway between.
    expect(energy(samples.sublist(4000, 4320)), greaterThan(20 * energy(samples.sublist(2000, 2320))));
    expect(track.beatTimes(const Duration(seconds: 2)), [
      Duration.zero,
      const Duration(milliseconds: 500),
      const Duration(milliseconds: 1000),
      const Duration(milliseconds: 1500),
    ]);
  });

  test('samples continue across takes and stay within -1 to 1', () {
    final whole = ClickTrack(bpm: 100, sampleRate: 8000, hats: true).take(6000);
    final parts = ClickTrack(bpm: 100, sampleRate: 8000, hats: true);
    final joined = [...parts.take(2500), ...parts.take(3500)];
    expect(joined, whole);
    expect(whole.every((v) => v >= -1 && v <= 1), isTrue);
  });

  test('the tempo can change, from the time it changes', () {
    final track = ClickTrack(bpm: 100, sampleRate: 8000)..changeAt(const Duration(seconds: 3), 150);
    final beats = track.beatTimes(const Duration(seconds: 4));
    expect(beats.where((b) => b < const Duration(seconds: 3)).length, 5);
    expect(beats.last - beats[beats.length - 2], const Duration(milliseconds: 400));
  });
}
