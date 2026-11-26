// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/music/audio_chunk.dart';
import 'package:lumen/music/music_analyser.dart';
import 'package:lumen/music/spectrum.dart';
import 'package:lumen/sim/click_track.dart';

void main() {
  const rate = 44100;
  const chunk = 1024;

  /// Feeds [seconds] of [track] as the microphone would: chunks of samples.
  List<MusicFrame> listen(MusicAnalyser a, ClickTrack track, double seconds) => [
    for (var i = 0; i < seconds * rate / chunk; i++)
      ...a.add(PcmChunk(Float64List.fromList(track.take(chunk)), sampleRate: rate)),
  ];

  /// How far [t] is from the nearest beat of [track].
  Duration offBeat(ClickTrack track, Duration t) {
    final beats = track.beatTimes(t + const Duration(seconds: 2));
    return beats.map((b) => (b - t).abs()).reduce((a, b) => a < b ? a : b);
  }

  for (final bpm in [85.0, 100.0, 120.0, 150.0]) {
    test('finds $bpm BPM and predicts the next beat from the microphone', () {
      final track = ClickTrack(bpm: bpm, sampleRate: rate, hats: true);
      final a = MusicAnalyser();
      listen(a, track, 8);
      expect(a.tracker.bpm, closeTo(bpm, 1.5));
      expect(a.tracker.locked, isTrue);
      final next = a.tracker.nextBeat(a.now)!;
      expect(next, greaterThanOrEqualTo(a.now));
      expect(offBeat(track, next), lessThan(const Duration(milliseconds: 25)));
    });
  }

  test('a fast track is found at its tempo or at half of it', () {
    final track = ClickTrack(bpm: 172, sampleRate: rate);
    final a = MusicAnalyser();
    listen(a, track, 8);
    final found = a.tracker.bpm!;
    expect((found - 172).abs() < 2 || (found - 86).abs() < 1, isTrue, reason: 'found $found');
    expect(offBeat(track, a.tracker.nextBeat(a.now)!), lessThan(const Duration(milliseconds: 25)));
  });

  test('follows the beat from 20 spectra a second, as the Visualizer gives', () {
    final track = ClickTrack(bpm: 120, sampleRate: rate, hats: true);
    final samples = track.take(rate * 10);
    final a = MusicAnalyser();
    for (var i = 1; i < 200; i++) {
      // Snapshots every 50 ms, with up to 9 ms of jitter as callbacks have.
      final at = Duration(milliseconds: i * 50 + (i * 7) % 10 - 4);
      final end = at.inMicroseconds * rate ~/ 1000000;
      final frame = Spectrum.magnitudes(samples.sublist(end - chunk, end));
      a.add(FftChunk(frame, sampleRate: rate, at: at));
    }
    expect(a.tracker.bpm, closeTo(120, 3));
    expect(a.tracker.locked, isTrue);
    expect(offBeat(track, a.tracker.nextBeat(a.now)!), lessThan(const Duration(milliseconds: 60)));
  });

  test('silence has no beat', () {
    final a = MusicAnalyser();
    for (var i = 0; i < 8 * rate / chunk; i++) {
      a.add(PcmChunk(Float64List(chunk), sampleRate: rate));
    }
    expect(a.tracker.locked, isFalse);
    expect(a.tracker.nextBeat(a.now), isNull);
  });

  test('steady noise has no beat', () {
    final track = ClickTrack(bpm: 120, sampleRate: rate, level: 0);
    final a = MusicAnalyser();
    listen(a, track, 8);
    expect(a.tracker.locked, isFalse);
  });

  test('follows a change of tempo within a few seconds', () {
    final track = ClickTrack(bpm: 100, sampleRate: rate)..changeAt(const Duration(seconds: 8), 130);
    final a = MusicAnalyser();
    listen(a, track, 8);
    expect(a.tracker.bpm, closeTo(100, 1.5));
    listen(a, track, 7);
    expect(a.tracker.bpm, closeTo(130, 1.5));
    expect(offBeat(track, a.tracker.nextBeat(a.now)!), lessThan(const Duration(milliseconds: 25)));
  });

  test('the level follows loudness, whatever the input gain', () {
    final a = MusicAnalyser();
    final loud = listen(a, ClickTrack(bpm: 120, sampleRate: rate, level: 0.1), 4);
    expect(loud.map((f) => f.level).reduce((x, y) => x > y ? x : y), greaterThan(0.8));
    final quiet = [for (var i = 0; i < 3 * rate / chunk; i++) ...a.add(PcmChunk(Float64List(chunk), sampleRate: rate))];
    expect(quiet.last.level, lessThan(0.05));
  });

  test('onsets land on the kicks', () {
    final track = ClickTrack(bpm: 120, sampleRate: rate);
    final a = MusicAnalyser();
    final onsets = listen(a, track, 4).where((f) => f.onset).toList();
    expect(onsets.length, inInclusiveRange(7, 9));
    for (final o in onsets) {
      expect(offBeat(track, o.at), lessThan(const Duration(milliseconds: 20)));
    }
  });
  test('names the lock tests that fail, and none once locked', () {
    final a = MusicAnalyser();
    expect(a.tracker.lockFailures, ['no tempo']);
    listen(a, ClickTrack(bpm: 120, sampleRate: rate, hats: true), 8);
    expect(a.tracker.locked, isTrue);
    expect(a.tracker.lockFailures, isEmpty);
  });

  test('steady noise fails the lock with a reason', () {
    final a = MusicAnalyser();
    listen(a, ClickTrack(bpm: 120, sampleRate: rate, level: 0), 8);
    expect(a.tracker.locked, isFalse);
    expect(a.tracker.lockFailures, isNotEmpty);
  });

  test('the grid predicts the same beat as nextBeat, and is null without a lock', () {
    final a = MusicAnalyser();
    expect(a.tracker.grid, isNull);
    listen(a, ClickTrack(bpm: 120, sampleRate: rate, hats: true), 8);
    expect(a.tracker.grid!.next(a.now), a.tracker.nextBeat(a.now));
    expect(a.tracker.grid!.period.inMicroseconds / 1e6, closeTo(0.5, 0.01));
  });

  test('reports each tempo estimate with its best candidates', () {
    final a = MusicAnalyser();
    listen(a, ClickTrack(bpm: 120, sampleRate: rate, hats: true), 8);
    expect(a.tracker.estimates, greaterThanOrEqualTo(14), reason: 'one every half second');
    final r = a.tracker.report;
    expect(r.locked, isTrue);
    expect(r.bpm, closeTo(120, 1.5));
    expect(r.candidates.first.$1, closeTo(120, 2));
    expect(r.candidates.first.$2, 1.0);
    expect(r.candidates.length, lessThanOrEqualTo(3));
    expect(r.format(), allOf(contains('120'), contains('locked')));
  });

  test('an onset frame carries its flux above its threshold, and every frame its peak and floor', () {
    final a = MusicAnalyser();
    final frames = listen(a, ClickTrack(bpm: 120, sampleRate: rate, hats: true), 4);
    final onsets = frames.where((f) => f.onset).toList();
    expect(onsets, isNotEmpty);
    for (final f in onsets) {
      expect(f.onsetFlux!, greaterThan(f.onsetThreshold!));
    }
    expect(frames.where((f) => !f.onset).every((f) => f.onsetFlux == null), isTrue);
    expect(frames.every((f) => f.floor > 0 && f.peak >= 0), isTrue);
  });

  int onsetCount(MusicAnalyser a, ClickTrack track) => listen(a, track, 8).where((f) => f.onset).length;

  test("the middle of each slider is the tracker's own rule", () {
    final plain = MusicAnalyser();
    final tuned = MusicAnalyser()..tracker.tune(sensitivity: 0.5, steadiness: 0.5);
    expect(onsetCount(tuned, ClickTrack(bpm: 120, sampleRate: rate, hats: true)),
        onsetCount(plain, ClickTrack(bpm: 120, sampleRate: rate, hats: true)));
    expect(tuned.tracker.report.confidenceNeeded, 0.55);
    expect(tuned.tracker.report.coverageNeeded, 0.6);
  });

  test('sensitivity moves the onset threshold', () {
    final keen = MusicAnalyser()..tracker.tune(sensitivity: 1, steadiness: 0.5);
    final dull = MusicAnalyser()..tracker.tune(sensitivity: 0, steadiness: 0.5);
    final keenFrames = listen(keen, ClickTrack(bpm: 120, sampleRate: rate, hats: true), 4);
    final dullFrames = listen(dull, ClickTrack(bpm: 120, sampleRate: rate, hats: true), 4);
    final keenAt = keenFrames.last.threshold!;
    final dullAt = dullFrames.last.threshold!;
    expect(keenAt, lessThan(dullAt));
    expect(keenFrames.where((f) => f.onset).length, greaterThanOrEqualTo(dullFrames.where((f) => f.onset).length));
  });

  test('steadiness sets what the lock needs, from loose to strict', () {
    final loose = MusicAnalyser()..tracker.tune(sensitivity: 0.5, steadiness: 0);
    final strict = MusicAnalyser()..tracker.tune(sensitivity: 0.5, steadiness: 1);
    expect(loose.tracker.report.confidenceNeeded, closeTo(0.35, 1e-9));
    expect(loose.tracker.report.coverageNeeded, closeTo(0.40, 1e-9));
    expect(strict.tracker.report.confidenceNeeded, closeTo(0.75, 1e-9));
    expect(strict.tracker.report.coverageNeeded, closeTo(0.80, 1e-9));
  });

  test('every frame carries its flux, and its threshold once there is half a second of history', () {
    final a = MusicAnalyser();
    final frames = listen(a, ClickTrack(bpm: 120, sampleRate: rate, hats: true), 2);
    expect(frames.every((f) => f.flux >= 0), isTrue);
    expect(frames.first.threshold, isNull);
    expect(frames.last.threshold, greaterThan(0));
  });

  test('the lock goes once no onset has come for a while, and says so', () {
    final a = MusicAnalyser();
    listen(a, ClickTrack(bpm: 120, sampleRate: rate, hats: true), 8);
    expect(a.tracker.locked, isTrue);
    for (var i = 0; i < 4 * rate / chunk; i++) {
      a.add(PcmChunk(Float64List(chunk), sampleRate: rate));
    }
    expect(a.tracker.lockFailures, contains(startsWith('last onset')));
  });

  test('onsets further apart than any tempo it looks for give no tempo', () {
    // Gaps of 2.64 s pass the longest interval the tempo search scores (three
    // periods at 70 BPM). Four such onsets fit in the 8 s window for only
    // about 0.1 s, so several starts make sure an estimate falls there.
    for (var shift = 0; shift < 500; shift += 20) {
      final a = MusicAnalyser();
      final hits = [for (var k = 0; k < 4; k++) 500 + shift + k * 2640];
      for (var ms = 20; ms <= 9500 + shift; ms += 20) {
        final loud = hits.contains(ms);
        final m = Float64List(512)..fillRange(0, 512, loud ? 60.0 : 1.0);
        a.add(FftChunk(m, sampleRate: rate, at: Duration(milliseconds: ms)));
      }
      expect(a.tracker.bpm, isNull, reason: 'shift $shift');
      expect(a.tracker.report.candidates, isEmpty);
    }
  });

  test('a low sample rate still gives frames, with a shorter window', () {
    final a = MusicAnalyser();
    final track = ClickTrack(bpm: 120, sampleRate: 22050, hats: true);
    final frames = [
      for (var i = 0; i < 4 * 22050 / 512; i++) ...a.add(PcmChunk(Float64List.fromList(track.take(512)), sampleRate: 22050)),
    ];
    expect(frames.length, greaterThan(300), reason: 'a 512 sample window, half overlapping, is about 86 a second');
  });

  test('a clock that jumps back does not break the tracker', () {
    final a = MusicAnalyser();
    void frame(int ms, double v) =>
        a.add(FftChunk(Float64List(512)..fillRange(0, 512, v), sampleRate: rate, at: Duration(milliseconds: ms)));
    for (var ms = 20; ms <= 20000; ms += 20) {
      frame(ms, 1);
    }
    // Frames from long before the newest: an onset among them is already
    // too old to keep.
    frame(1000, 1);
    frame(1020, 60);
    expect(() => frame(1040, 1), returnsNormally);
  });

  test('locked agrees with the lock failures on every frame, through music, noise and silence', () {
    final a = MusicAnalyser();
    final music = ClickTrack(bpm: 120, sampleRate: rate, hats: true);
    final noise = ClickTrack(bpm: 120, sampleRate: rate, level: 0);
    var checked = 0;
    for (var i = 0; i < 16 * rate / chunk; i++) {
      final seconds = i * chunk / rate;
      final samples = seconds < 8 ? music.take(chunk) : (seconds < 12 ? noise.take(chunk) : List.filled(chunk, 0.0));
      a.add(PcmChunk(Float64List.fromList(samples), sampleRate: rate));
      expect(a.tracker.locked, a.tracker.lockFailures.isEmpty, reason: 'at ${seconds.toStringAsFixed(2)} s');
      if (a.tracker.locked) checked++;
    }
    expect(checked, greaterThan(0), reason: 'it locked at some point');
  });
}
