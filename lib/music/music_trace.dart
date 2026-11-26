// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'beat_tracker.dart';

/// What happened to a beat music sync timed.
enum BeatOutcome {
  fired,

  /// Fired from a held grid after the lock was lost.
  held,

  /// Fired on an onset as it was heard.
  hit,

  /// Dropped: the lights were still busy with the last one.
  busy,

  /// Dropped: too soon after the last flash.
  tooSoon,
}

/// A ring of times in microseconds, each with two values and a kind, in
/// typed arrays allocated once: when full, the newest overwrites the
/// oldest.
class _Ring {
  _Ring(this.capacity)
    : times = Int64List(capacity),
      a = Float64List(capacity),
      b = Float64List(capacity),
      kinds = Uint8List(capacity);

  final int capacity;
  final Int64List times;
  final Float64List a;
  final Float64List b;
  final Uint8List kinds;
  int _start = 0;
  int length = 0;

  /// The slot of the [k]th entry, oldest first.
  int slot(int k) => (_start + k) % capacity;

  int get last => slot(length - 1);

  void add(int time, {double a = 0, double b = double.nan, int kind = 0}) {
    final int i;
    if (length == capacity) {
      i = _start;
      _start = (_start + 1) % capacity;
    } else {
      i = slot(length);
      length++;
    }
    times[i] = time;
    this.a[i] = a;
    this.b[i] = b;
    kinds[i] = kind;
  }

  /// Drops the entries before [time], oldest first, while [keep] allows.
  void dropBefore(int time, [bool Function(int slot)? keep]) {
    while (length > 0 && times[_start] < time && (keep == null || !keep(_start))) {
      _start = (_start + 1) % capacity;
      length--;
    }
  }

  void clear() {
    _start = 0;
    length = 0;
  }
}

/// The last few seconds of what music sync heard and did, on the audio
/// clock, for the trace on the Music sync screen, which repaints when told
/// a chunk has been added. Everything lives in rings allocated once.
class MusicTrace extends ChangeNotifier {
  static const keep = Duration(seconds: 6);
  static const _levelEvery = Duration(milliseconds: 50);

  /// Frames kept: six seconds of the microphone's 86 a second, with room.
  static const frameCapacity = 1024;

  /// Onsets and beats kept: more than six seconds' worth at any tempo.
  static const markCapacity = 128;
  static const _levelCapacity = 256;
  static const _breathCapacity = 16;

  final _levels = _Ring(_levelCapacity);
  final _fluxes = _Ring(frameCapacity);
  final _onsets = _Ring(markCapacity);
  final _beats = _Ring(markCapacity);

  /// Breathing spans: start in [_Ring.times], end in microseconds in a, or
  /// NaN while breathing.
  final _breaths = _Ring(_breathCapacity);

  /// The newest time heard.
  Duration now = Duration.zero;

  /// How many times its threshold an onset must reach to be a hit, for the
  /// hit line; music sync keeps it in step with Sensitivity.
  double hitMargin = 1.6;

  static Duration _d(int us) => Duration(microseconds: us);

  /// Copies for tests and the log; the painter reads the rings through
  /// [TraceLayout].
  List<(Duration, double)> get levels => [
    for (var k = 0; k < _levels.length; k++) (_d(_levels.times[_levels.slot(k)]), _levels.a[_levels.slot(k)]),
  ];

  /// Each frame's onset signal and the threshold an onset had to pass.
  List<(Duration, double, double?)> get fluxes => [
    for (var k = 0; k < _fluxes.length; k++)
      (
        _d(_fluxes.times[_fluxes.slot(k)]),
        _fluxes.a[_fluxes.slot(k)],
        _fluxes.b[_fluxes.slot(k)].isNaN ? null : _fluxes.b[_fluxes.slot(k)],
      ),
  ];

  List<Duration> get onsets => [for (var k = 0; k < _onsets.length; k++) _d(_onsets.times[_onsets.slot(k)])];

  List<(Duration, BeatOutcome)> get beats => [
    for (var k = 0; k < _beats.length; k++)
      (_d(_beats.times[_beats.slot(k)]), BeatOutcome.values[_beats.kinds[_beats.slot(k)]]),
  ];

  /// Breathing spans, start and end; the end is null while breathing.
  List<(Duration, Duration?)> get breaths => [
    for (var k = 0; k < _breaths.length; k++)
      (
        _d(_breaths.times[_breaths.slot(k)]),
        _breaths.a[_breaths.slot(k)].isNaN ? null : _d(_breaths.a[_breaths.slot(k)].toInt()),
      ),
  ];

  void addFrame(MusicFrame f) {
    if (f.at > now) now = f.at;
    final t = f.at.inMicroseconds;
    if (f.onset) _onsets.add(t);
    _fluxes.add(t, a: f.flux, b: f.threshold ?? double.nan);
    if (_levels.length == 0 || t - _levels.times[_levels.last] >= _levelEvery.inMicroseconds) {
      _levels.add(t, a: f.level);
    }
    _prune();
  }

  void addBeat(Duration at, BeatOutcome outcome) {
    _beats.add(at.inMicroseconds, kind: outcome.index);
    _prune();
  }

  void setBreathing(Duration at, bool on) {
    final open = _breaths.length > 0 && _breaths.a[_breaths.last].isNaN;
    if (on && !open) _breaths.add(at.inMicroseconds, a: double.nan);
    if (!on && open) _breaths.a[_breaths.last] = at.inMicroseconds.toDouble();
  }

  /// Tells listeners a chunk has been added.
  void publish() => notifyListeners();

  void clear() {
    _levels.clear();
    _fluxes.clear();
    _onsets.clear();
    _beats.clear();
    _breaths.clear();
    now = Duration.zero;
  }

  void _prune() {
    final from = (now - keep).inMicroseconds;
    _levels.dropBefore(from);
    _fluxes.dropBefore(from);
    _onsets.dropBefore(from);
    _beats.dropBefore(from);
    // A breath goes once it has ended before the window.
    _breaths.dropBefore(from, (i) => _breaths.a[i].isNaN || _breaths.a[i] >= from);
  }
}

/// Where the trace's marks go in a box of a given size, in buffers
/// allocated once and refilled on every paint: time runs left to right
/// over the span, the newest at the right edge; the level runs from the
/// bottom (quiet) to the top (loud); the onset signal is drawn as bars in
/// the lower [fluxShare] of the box, scaled to the largest signal or
/// threshold shown, with the threshold as a line on the same scale.
class TraceLayout {
  /// The share of the height the onset signal may use: beat marks sit
  /// above it.
  static const fluxShare = 0.8;

  /// Bars as line segments, x, bottom, x, top: ready for `drawRawPoints`.
  final Float32List bars = Float32List(MusicTrace.frameCapacity * 4);
  int barCount = 0;

  /// The threshold line and the level outline, as x, y pairs.
  final Float32List thresholdPoints = Float32List(MusicTrace.frameCapacity * 2);
  int thresholdCount = 0;
  final Float32List hitPoints = Float32List(MusicTrace.frameCapacity * 2);
  int hitCount = 0;
  final Float32List levelPoints = Float32List(MusicTrace._levelCapacity * 2);
  int levelCount = 0;

  final Float32List onsetXs = Float32List(MusicTrace.markCapacity);
  int onsetCount = 0;
  final Float32List beatXs = Float32List(MusicTrace.markCapacity);
  final Uint8List beatKinds = Uint8List(MusicTrace.markCapacity);
  int beatCount = 0;

  /// Breathing spans as x0, x1 pairs.
  final Float32List breathSpans = Float32List(MusicTrace._breathCapacity * 2);
  int breathCount = 0;

  /// Every buffer, so a test can see they are the same from one paint to
  /// the next.
  List<TypedData> get buffers => [bars, thresholdPoints, hitPoints, levelPoints, onsetXs, beatXs, beatKinds, breathSpans];

  void update(MusicTrace trace, Size size, {Duration span = const Duration(seconds: 5)}) {
    final nowUs = trace.now.inMicroseconds;
    final spanUs = span.inMicroseconds;
    final fromUs = nowUs - spanUs;
    final w = size.width;
    final h = size.height;
    double x(int t) => w * (t - fromUs) / spanUs;
    bool shown(int t) => t >= fromUs && t <= nowUs;

    final fl = trace._fluxes;
    final hit = trace.hitMargin;
    var top = 0.0;
    for (var k = 0; k < fl.length; k++) {
      final i = fl.slot(k);
      if (!shown(fl.times[i])) continue;
      if (fl.a[i] > top) top = fl.a[i];
      final threshold = fl.b[i];
      // The hit line is the highest line: the margin is always above 1.
      if (!threshold.isNaN && threshold * hit > top) top = threshold * hit;
    }
    final scale = top == 0 ? 0.0 : h * fluxShare / top;
    barCount = 0;
    thresholdCount = 0;
    hitCount = 0;
    for (var k = 0; k < fl.length; k++) {
      final i = fl.slot(k);
      final t = fl.times[i];
      if (!shown(t)) continue;
      final bx = x(t);
      final j = barCount++ * 4;
      bars[j] = bx;
      bars[j + 1] = h;
      bars[j + 2] = bx;
      bars[j + 3] = h - fl.a[i] * scale;
      final threshold = fl.b[i];
      if (!threshold.isNaN) {
        final p = thresholdCount++ * 2;
        thresholdPoints[p] = bx;
        thresholdPoints[p + 1] = h - threshold * scale;
        final q = hitCount++ * 2;
        hitPoints[q] = bx;
        hitPoints[q + 1] = h - threshold * hit * scale;
      }
    }

    final lv = trace._levels;
    levelCount = 0;
    for (var k = 0; k < lv.length; k++) {
      final i = lv.slot(k);
      if (!shown(lv.times[i])) continue;
      final p = levelCount++ * 2;
      levelPoints[p] = x(lv.times[i]);
      levelPoints[p + 1] = h * (1 - lv.a[i].clamp(0.0, 1.0));
    }

    final on = trace._onsets;
    onsetCount = 0;
    for (var k = 0; k < on.length; k++) {
      final t = on.times[on.slot(k)];
      if (shown(t)) onsetXs[onsetCount++] = x(t);
    }

    final bt = trace._beats;
    beatCount = 0;
    for (var k = 0; k < bt.length; k++) {
      final i = bt.slot(k);
      if (!shown(bt.times[i])) continue;
      beatXs[beatCount] = x(bt.times[i]);
      beatKinds[beatCount++] = bt.kinds[i];
    }

    final br = trace._breaths;
    breathCount = 0;
    for (var k = 0; k < br.length; k++) {
      final i = br.slot(k);
      final end = br.a[i].isNaN ? nowUs : br.a[i].toInt();
      if (end < fromUs) continue;
      final start = br.times[i] < fromUs ? fromUs : br.times[i];
      final p = breathCount++ * 2;
      breathSpans[p] = x(start);
      breathSpans[p + 1] = x(end);
    }
  }

  // Copies, for tests.
  List<(double, double)> get flux => [
    for (var k = 0; k < barCount; k++) (bars[k * 4] + 0.0, bars[k * 4 + 1] - bars[k * 4 + 3] + 0.0),
  ];
  List<Offset> get threshold => [
    for (var k = 0; k < thresholdCount; k++) Offset(thresholdPoints[k * 2], thresholdPoints[k * 2 + 1]),
  ];
  List<Offset> get hitLine => [for (var k = 0; k < hitCount; k++) Offset(hitPoints[k * 2], hitPoints[k * 2 + 1])];
  List<Offset> get level => [for (var k = 0; k < levelCount; k++) Offset(levelPoints[k * 2], levelPoints[k * 2 + 1])];
  List<double> get onsets => [for (var k = 0; k < onsetCount; k++) onsetXs[k]];
  List<(double, BeatOutcome)> get beats => [
    for (var k = 0; k < beatCount; k++) (beatXs[k] + 0.0, BeatOutcome.values[beatKinds[k]]),
  ];
  List<(double, double)> get breathing => [
    for (var k = 0; k < breathCount; k++) (breathSpans[k * 2] + 0.0, breathSpans[k * 2 + 1] + 0.0),
  ];
}
