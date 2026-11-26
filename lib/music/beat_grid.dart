// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

/// A steady beat: one every [period] from [anchor], on the audio clock.
class BeatGrid {
  const BeatGrid({required this.period, required this.anchor});

  final Duration period;

  /// The time of one beat, usually the latest heard.
  final Duration anchor;

  /// The first beat at or after [t].
  Duration next(Duration t) {
    final p = period.inMicroseconds;
    final n = ((t - anchor).inMicroseconds / p).ceil();
    return anchor + Duration(microseconds: n * p);
  }

  @override
  bool operator ==(Object other) => other is BeatGrid && other.period == period && other.anchor == anchor;

  @override
  int get hashCode => Object.hash(period, anchor);

  @override
  String toString() => 'BeatGrid(${period.inMilliseconds} ms from ${anchor.inMilliseconds} ms)';
}
