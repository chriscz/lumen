// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:typed_data';

import 'audio_chunk.dart';
import 'beat_tracker.dart';
import 'spectrum.dart';

export 'beat_tracker.dart' show BeatTracker, MusicFrame;

/// Turns audio chunks into analysis frames for a [BeatTracker], and keeps
/// the audio clock: the time of the newest sound heard.
class MusicAnalyser {
  MusicAnalyser({BeatTracker? tracker}) : tracker = tracker ?? BeatTracker();

  final BeatTracker tracker;

  /// The time of the newest sound heard, on the audio clock. For samples it
  /// counts samples; for spectra it is the time of the latest snapshot.
  Duration get now => _now;
  Duration _now = Duration.zero;

  final List<double> _buffer = [];
  int _rate = 0;

  /// Samples dropped from the front of [_buffer] so far.
  int _start = 0;

  /// The quietest magnitude worth hearing: samples run from -1 to 1, the
  /// Visualizer's spectrum from -128 to 127.
  static const _pcmFloor = 1e-4;
  static const _fftFloor = 2.0;

  /// Analyses [chunk] and returns a frame per window of it.
  List<MusicFrame> add(AudioChunk chunk) => switch (chunk) {
    PcmChunk() => _addPcm(chunk),
    FftChunk() => _addFft(chunk),
  };

  List<MusicFrame> _addPcm(PcmChunk chunk) {
    if (chunk.sampleRate != _rate) {
      _rate = chunk.sampleRate;
      _buffer.clear();
      _start = (_now.inMicroseconds * _rate / 1e6).round();
    }
    final window = _rate >= 32000
        ? 1024
        : _rate >= 16000
        ? 512
        : 256;
    final hop = window ~/ 2;
    _buffer.addAll(chunk.samples);
    _now = _time(_start + _buffer.length);
    final frames = <MusicFrame>[];
    while (_buffer.length >= window) {
      final magnitudes = Spectrum.magnitudes(Float64List.fromList(_buffer.sublist(0, window)));
      frames.add(
        tracker.add(magnitudes, binHz: _rate / window, at: _time(_start + window ~/ 2), floor: _pcmFloor),
      );
      _buffer.removeRange(0, hop);
      _start += hop;
    }
    return frames;
  }

  List<MusicFrame> _addFft(FftChunk chunk) {
    final n = 2 * (chunk.magnitudes.length - 1);
    if (n <= 0) return const [];
    _now = chunk.at;
    final half = Duration(microseconds: n * 500000 ~/ chunk.sampleRate);
    return [
      tracker.add(chunk.magnitudes, binHz: chunk.sampleRate / n, at: chunk.at - half, floor: _fftFloor),
    ];
  }

  Duration _time(int samples) => Duration(microseconds: samples * 1000000 ~/ _rate);
}
