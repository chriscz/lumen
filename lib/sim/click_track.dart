// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:math';

/// Synthetic music with a known beat: a kick drum on every beat, optional
/// hi-hats on the off-beats and a quiet noise floor. It stands in for the
/// microphone and the phone's sound in tests and demo mode. The same sample
/// index always gives the same sample, so takes join without a seam.
class ClickTrack {
  ClickTrack({required double bpm, this.sampleRate = 44100, this.hats = false, this.level = 0.8})
    : _segments = [(Duration.zero, bpm)];

  final int sampleRate;

  /// Whether hi-hats play halfway between beats.
  final bool hats;

  /// The kick's peak, from 0 to 1.
  final double level;

  final List<(Duration, double)> _segments;
  final List<Duration> _beats = [];
  int _next = 0;

  /// Plays at [bpm] from [at], with the first beat of the new tempo on [at].
  void changeAt(Duration at, double bpm) {
    _segments
      ..add((at, bpm))
      ..sort((a, b) => a.$1.compareTo(b.$1));
    _beats.clear();
  }

  /// The beats before [end].
  List<Duration> beatTimes(Duration end) {
    _extend(end);
    return _beats.where((b) => b < end).toList();
  }

  void _extend(Duration end) {
    if (_beats.isNotEmpty && _beats.last >= end) return;
    _beats.clear();
    for (var s = 0; s < _segments.length; s++) {
      final (start, bpm) = _segments[s];
      final stop = s + 1 < _segments.length ? _segments[s + 1].$1 : null;
      final period = Duration(microseconds: (60e6 / bpm).round());
      for (var t = start; (stop == null || t < stop); t += period) {
        _beats.add(t);
        if (stop == null && t > end) break;
      }
    }
  }

  /// The next [count] samples.
  List<double> take(int count) => [for (var i = 0; i < count; i++) sampleAt(_next++)];

  /// The sample at [index], from -1 to 1.
  double sampleAt(int index) {
    final t = index / sampleRate;
    final at = Duration(microseconds: (t * 1e6).floor());
    _extend(at + const Duration(seconds: 1));
    var lo = 0;
    var hi = _beats.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_beats[mid] <= at) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final beat = _beats[lo].inMicroseconds / 1e6;
    final dt = t - beat;
    var v = 0.01 * _noise(index);
    if (dt >= 0 && dt < 0.4) {
      final pitch = 55 + 90 * exp(-dt / 0.012);
      v += level * exp(-dt / 0.04) * sin(2 * pi * pitch * dt) + 0.3 * level * exp(-dt / 0.004) * _noise(index + 7);
    }
    if (hats && lo + 1 < _beats.length) {
      final half = beat + (_beats[lo + 1].inMicroseconds / 1e6 - beat) / 2;
      final dh = t - half;
      if (dh >= 0 && dh < 0.04) v += 0.2 * level * exp(-dh / 0.008) * _noise(index + 13);
    }
    return v.clamp(-1.0, 1.0);
  }

  /// White noise from -1 to 1 that depends only on [i].
  static double _noise(int i) {
    var x = (i * 0x9E3779B1) & 0xFFFFFFFF;
    x ^= x >> 16;
    x = (x * 0x85EBCA6B) & 0xFFFFFFFF;
    x ^= x >> 13;
    x = (x * 0xC2B2AE35) & 0xFFFFFFFF;
    x ^= x >> 16;
    return x / 0x7FFFFFFF - 1;
  }
}
