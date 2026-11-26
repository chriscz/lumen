// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/music/beat_tracker.dart';
import 'package:lumen/music/music_trace.dart';

void main() {
  Duration ms(int v) => Duration(milliseconds: v);
  MusicFrame frame(int at, {double level = 0.5, bool onset = false}) =>
      MusicFrame(at: ms(at), level: level, bass: 0, onset: onset);

  test('keeps six seconds of levels, onsets, beats and breaths', () {
    final t = MusicTrace();
    for (var i = 0; i <= 8000; i += 10) {
      t.addFrame(frame(i, onset: i % 500 == 0));
    }
    t.addBeat(ms(1000), BeatOutcome.fired);
    t.addBeat(ms(7500), BeatOutcome.held);
    expect(t.now, ms(8000));
    expect(t.levels.first.$1, greaterThanOrEqualTo(ms(2000)));
    expect(t.levels.length, lessThanOrEqualTo(121), reason: 'a level every 50 ms at most');
    expect(t.onsets.first, ms(2000));
    expect(t.beats, [(ms(7500), BeatOutcome.held)]);
  });

  test('lays out the last five seconds from left to right, the newest at the right edge', () {
    final t = MusicTrace();
    t.addFrame(frame(0, level: 0));
    t.addFrame(frame(2000, level: 1, onset: true));
    t.addFrame(frame(5000, level: 0.5));
    t.addFrame(frame(6000, level: 0.25));
    t.addBeat(ms(3500), BeatOutcome.busy);
    t.setBreathing(ms(4000), true);
    final m = (TraceLayout()..update(t, const Size(500, 100)));
    expect(m.level.first, const Offset(100, 0), reason: 'the 2 s frame, 4 s old');
    expect(m.level.last, const Offset(500, 75));
    expect(m.onsets, [100.0]);
    expect(m.beats, [(250.0, BeatOutcome.busy)]);
    expect(m.breathing, [(300.0, 500.0)]);
  });

  test('a breath that ended stays drawn until it scrolls off', () {
    final t = MusicTrace();
    t.addFrame(frame(0));
    t.setBreathing(ms(1000), true);
    t.setBreathing(ms(2000), false);
    t.addFrame(frame(3000));
    expect((TraceLayout()..update(t, const Size(500, 100))).breathing, [(300.0, 400.0)]);
    t.addFrame(frame(8000));
    expect((TraceLayout()..update(t, const Size(500, 100))).breathing, isEmpty);
  });

  test("draws each frame's onset signal as a bar and its threshold as a line, scaled to the largest on screen", () {
    final t = MusicTrace();
    t.addFrame(const MusicFrame(at: Duration(seconds: 1), level: 0, bass: 0, flux: 0.2));
    t.addFrame(const MusicFrame(at: Duration(seconds: 5), level: 0, bass: 0, flux: 0.5, threshold: 0.25));
    t.addFrame(const MusicFrame(at: Duration(seconds: 6), level: 0, bass: 0, flux: 1.0, threshold: 0.5));
    final m = (TraceLayout()..update(t, const Size(500, 100)));
    expect(m.flux, [(0.0, 16.0), (400.0, 40.0), (500.0, 80.0)], reason: 'bars use the lower 80%');
    expect(m.threshold, [const Offset(400, 80), const Offset(500, 60)]);
  });

  test('tells its listeners when a chunk has been added', () {
    final t = MusicTrace();
    var told = 0;
    t.addListener(() => told++);
    t.addFrame(const MusicFrame(at: Duration(seconds: 1), level: 0, bass: 0));
    expect(told, 0);
    t.publish();
    expect(told, 1);
  });

  test('a breath that ended more than six seconds ago is let go', () {
    final t = MusicTrace();
    t.addFrame(frame(0));
    t.setBreathing(ms(500), true);
    t.setBreathing(ms(1000), false);
    t.setBreathing(ms(7000), true);
    t.addFrame(frame(7500));
    expect(t.breaths, [(ms(7000), null)]);
  });

  test('keeps a fixed amount whatever it is fed, the newest kept', () {
    final t = MusicTrace();
    for (var i = 0; i < 20000; i++) {
      t.addFrame(MusicFrame(at: ms(i), level: 0.5, bass: 0, onset: i % 10 == 0, flux: i.toDouble()));
      t.addBeat(ms(i), BeatOutcome.fired);
    }
    expect(t.fluxes.length, lessThanOrEqualTo(MusicTrace.frameCapacity));
    expect(t.fluxes.last.$2, 19999);
    expect(t.beats.length, lessThanOrEqualTo(MusicTrace.markCapacity));
    expect(t.onsets.last, ms(19990));
  });

  test('the layout reuses its buffers from one paint to the next', () {
    final t = MusicTrace()..addFrame(const MusicFrame(at: Duration(seconds: 1), level: 0.5, bass: 0, flux: 1));
    final layout = TraceLayout()..update(t, const Size(500, 100));
    final buffers = layout.buffers;
    t.addFrame(const MusicFrame(at: Duration(seconds: 2), level: 0.5, bass: 0, flux: 1));
    layout.update(t, const Size(500, 100));
    expect(layout.flux.length, 2);
    for (var i = 0; i < buffers.length; i++) {
      expect(identical(layout.buffers[i], buffers[i]), isTrue);
    }
  });

  test('the line an onset must reach to be a hit is drawn above the threshold, on the same scale', () {
    final t = MusicTrace()..hitMargin = 2;
    t.addFrame(const MusicFrame(at: Duration(seconds: 5), level: 0, bass: 0, flux: 0.5, threshold: 0.25));
    t.addFrame(const MusicFrame(at: Duration(seconds: 6), level: 0, bass: 0, flux: 1.0, threshold: 0.5));
    final m = TraceLayout()..update(t, const Size(500, 100));
    expect(m.hitLine, [const Offset(400, 60), const Offset(500, 20)]);
  });
}
